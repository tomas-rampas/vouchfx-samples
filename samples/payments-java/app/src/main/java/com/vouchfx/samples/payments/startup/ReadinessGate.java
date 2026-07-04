package com.vouchfx.samples.payments.startup;

import com.vouchfx.samples.payments.messaging.NatsPublisher;
import com.vouchfx.samples.payments.repository.PaymentRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.stereotype.Component;

import java.net.URI;
import java.net.URISyntaxException;
import java.time.Duration;
import java.time.Instant;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Resilient startup gate: retries the SQL Server schema check and the NATS JetStream
 * connect/stream-ensure step until both succeed, because either dependency container can
 * still be starting when this application's process starts — SQL Server in particular
 * routinely takes 15-45s to accept connections after its container reports "running" (see
 * README.md "Troubleshooting"). {@code GET /} reports {@code 503} until both succeed, then
 * {@code 200} — the vouchfx engine health-gates each service on {@code GET /} returning 2xx
 * before running any suite steps, so this is the mechanism that makes the "~60s retry"
 * requirement observable from outside the container.
 *
 * <p>Runs as a Spring {@link ApplicationRunner}, which executes on the main thread AFTER the
 * embedded web server has already started accepting connections — so {@code GET /} can be
 * polled (and correctly returns 503) while this loop is still retrying in the background.
 *
 * <p>Deliberately has no hard timeout: SQL Server container start time is a documented
 * source of variance (slow CI/dev-machine disks can push well past a minute), and giving up
 * and crash-looping the process would be strictly worse than staying up and reporting 503.
 * The vouchfx engine's own health-gate timeout is what ultimately bounds how long a suite
 * run waits for this service to become healthy.
 *
 * <p>Requires {@code spring.datasource.hikari.initialization-fail-timeout=-1} (set in
 * application.yml) — without it, Spring Boot's autoconfigured {@code HikariDataSource} bean
 * would try to validate a connection eagerly during application-context startup and throw
 * before this runner ever gets to retry, crashing the whole process if SQL Server is not yet
 * reachable.
 */
@Component
public class ReadinessGate implements ApplicationRunner {

    private static final Logger log = LoggerFactory.getLogger(ReadinessGate.class);
    private static final Duration RETRY_DELAY = Duration.ofSeconds(2);
    private static final Duration STRAGGLER_WARNING_THRESHOLD = Duration.ofSeconds(60);

    private final PaymentRepository paymentRepository;
    private final NatsPublisher natsPublisher;
    private final AtomicBoolean ready = new AtomicBoolean(false);

    public ReadinessGate(PaymentRepository paymentRepository, NatsPublisher natsPublisher) {
        this.paymentRepository = paymentRepository;
        this.natsPublisher = natsPublisher;
    }

    public boolean isReady() {
        return ready.get();
    }

    @Override
    public void run(ApplicationArguments args) throws Exception {
        String natsUrl = System.getenv("NATS_URL");
        Instant started = Instant.now();
        boolean schemaReady = false;
        boolean natsReady = false;
        int attempt = 0;
        boolean warnedStraggler = false;

        while (!(schemaReady && natsReady)) {
            attempt++;

            if (!schemaReady) {
                try {
                    paymentRepository.ensureSchema();
                    schemaReady = true;
                    log.info("SQL Server schema ready (payments table present) after {} attempt(s), {}.",
                            attempt, Duration.between(started, Instant.now()));
                } catch (Exception e) {
                    log.warn("Attempt {}: waiting for SQL Server ({} elapsed): {}",
                            attempt, Duration.between(started, Instant.now()), e.getMessage());
                }
            }

            if (!natsReady) {
                try {
                    natsPublisher.connectAndEnsureStream(natsUrl);
                    natsReady = true;
                    log.info("NATS JetStream ready (subject={}, stream={}) after {} attempt(s), {}.",
                            NatsPublisher.SUBJECT, NatsPublisher.STREAM_NAME, attempt,
                            Duration.between(started, Instant.now()));
                } catch (Exception e) {
                    // Deliberately NOT e.getMessage(): NATS_URL (and therefore the client
                    // library's own exception text) can carry the "nats://user:pass@host:port"
                    // form -- the managed dependency is provisioned with credentials. Log the
                    // exception class plus a redacted host:port only, never the raw message.
                    log.warn("Attempt {}: waiting for NATS at {} ({} elapsed): {}",
                            attempt, redactNatsUrl(natsUrl), Duration.between(started, Instant.now()),
                            e.getClass().getName());
                }
            }

            if (schemaReady && natsReady) {
                break;
            }

            Duration elapsed = Duration.between(started, Instant.now());
            if (!warnedStraggler && elapsed.compareTo(STRAGGLER_WARNING_THRESHOLD) > 0) {
                warnedStraggler = true;
                log.warn("Startup has exceeded the expected ~60s window ({} elapsed); "
                        + "still retrying -- see README.md Troubleshooting for SQL Server startup slowness.",
                        elapsed);
            }

            Thread.sleep(RETRY_DELAY.toMillis());
        }

        ready.set(true);
        log.info("Startup complete after {} -- service is ready.", Duration.between(started, Instant.now()));
    }

    /**
     * Reduces a NATS connection URL to {@code scheme://host:port} for logging, stripping any
     * {@code user:pass@} userinfo component. Used instead of ever logging {@code NATS_URL}
     * itself, or an exception message derived from it, verbatim.
     */
    private static String redactNatsUrl(String natsUrl) {
        if (natsUrl == null || natsUrl.isBlank()) {
            return "(unset)";
        }
        try {
            URI uri = new URI(natsUrl);
            String scheme = uri.getScheme() != null ? uri.getScheme() : "nats";
            String host = uri.getHost() != null ? uri.getHost() : "?";
            int port = uri.getPort();
            return port >= 0 ? scheme + "://" + host + ":" + port : scheme + "://" + host;
        } catch (URISyntaxException e) {
            return "(unparseable)";
        }
    }
}
