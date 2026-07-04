package com.vouchfx.samples.payments.messaging;

import io.nats.client.Connection;
import io.nats.client.JetStream;
import io.nats.client.JetStreamApiException;
import io.nats.client.JetStreamManagement;
import io.nats.client.Nats;
import io.nats.client.api.StorageType;
import io.nats.client.api.StreamConfiguration;
import jakarta.annotation.PreDestroy;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.io.IOException;

/**
 * Owns the single long-lived NATS connection and JetStream context used to publish
 * payment-authorised events.
 *
 * <h2>JetStream stream-ownership note (read before touching subject/stream naming)</h2>
 * The vouchfx engine's {@code mq-expect.nats} step provider
 * ({@code Platform.Steps.MqExpect.Nats.MqExpectNatsProvider} in the vouchfx engine repo)
 * consumes via an ephemeral <em>ordered</em> JetStream consumer that scans its stream from
 * the START of the retained log on every attempt ({@code DeliverPolicy.All}, mirroring
 * {@code mq-expect.kafka}'s retained-log semantics). That provider ensures its stream exists
 * too (idempotent {@code CreateStreamAsync}, tolerating NATS API error code 10058 "stream
 * name already in use") — but only the <em>first time its own step actually executes</em>,
 * which in {@code tests/payments.e2e.yaml} is step 3, well AFTER step 1 (the
 * {@code http.rest} call) has already told this application to publish.
 *
 * <p>A JetStream publish issued before any stream captures the target subject is
 * unrecoverable: on core-NATS semantics the message is a fire-and-forget publish with no
 * subscriber and simply vanishes, and via {@link JetStream#publish} the broker either
 * returns "no responders"/an ack timeout or, if it silently accepted the publish, there is
 * still no stream to retroactively record it against. Either way, by the time the suite's
 * {@code mq-expect.nats} step runs and creates its stream, an earlier message is gone for
 * good.
 *
 * <p>To guarantee delivery, this application therefore creates the <em>same</em> stream,
 * over the <em>same</em> subject, during its own resilient startup sequence — well before
 * the embedded server can accept the first {@code POST /payments} request. The engine
 * provider derives its stream name from the subject when the step omits an explicit
 * {@code stream:} field (uppercase the subject, replace every character that is not
 * {@code [A-Za-z0-9-]} with {@code _}, collapse repeats, trim leading/trailing {@code _}) —
 * for {@code "payments.authorised"} that derivation yields {@code "PAYMENTS_AUTHORISED"}.
 * Rather than have both sides independently re-implement that derivation rule (a single
 * typo in either place would silently split the stream in two), {@code
 * tests/payments.e2e.yaml} pins the {@code stream:} field on the {@code mq-expect.nats}
 * step explicitly to {@link #STREAM_NAME}, and this class uses the identical literal.
 *
 * <p>{@link JetStreamManagement#addStream} is documented by the NATS Java client itself as
 * "Loads or creates a stream" (idempotent get-or-create); this class additionally tolerates
 * API error code 10058 exactly as the engine provider does, in case of a benign race with a
 * concurrent creator.
 */
@Component
public class NatsPublisher {

    private static final Logger log = LoggerFactory.getLogger(NatsPublisher.class);

    /** Subject the engine's mq-expect.nats step asserts against (tests/payments.e2e.yaml). */
    public static final String SUBJECT = "payments.authorised";

    /** Must equal the 'stream:' field pinned on that step — see the class Javadoc above. */
    public static final String STREAM_NAME = "PAYMENTS_AUTHORISED";

    /** NATS JetStream API error code for "stream name already in use". */
    private static final int STREAM_ALREADY_IN_USE_ERROR_CODE = 10058;

    private volatile Connection connection;
    private volatile JetStream jetStream;

    /**
     * Connects to NATS and ensures the JetStream stream exists. Intended to be called from
     * the resilient startup retry loop ({@code ReadinessGate}); throws on any failure so the
     * caller can retry with backoff.
     */
    public void connectAndEnsureStream(String natsUrl) throws IOException, InterruptedException, JetStreamApiException {
        if (natsUrl == null || natsUrl.isBlank()) {
            throw new IOException("NATS_URL is not set");
        }

        Connection nc = Nats.connect(natsUrl);
        boolean success = false;
        try {
            JetStreamManagement jsm = nc.jetStreamManagement();
            StreamConfiguration streamConfig = StreamConfiguration.builder()
                    .name(STREAM_NAME)
                    .subjects(SUBJECT)
                    .storageType(StorageType.File)
                    .build();
            try {
                jsm.addStream(streamConfig);
                log.info("JetStream stream '{}' ensured for subject '{}'.", STREAM_NAME, SUBJECT);
            } catch (JetStreamApiException e) {
                if (e.getApiErrorCode() != STREAM_ALREADY_IN_USE_ERROR_CODE) {
                    throw e;
                }
                log.info("JetStream stream '{}' already exists (error code {}); continuing.",
                        STREAM_NAME, STREAM_ALREADY_IN_USE_ERROR_CODE);
            }

            this.jetStream = nc.jetStream();
            this.connection = nc;
            success = true;
        } finally {
            if (!success) {
                try {
                    nc.close();
                } catch (InterruptedException closeInterrupted) {
                    Thread.currentThread().interrupt();
                }
            }
        }
    }

    /** Publishes the given JSON payload to {@link #SUBJECT} via JetStream (waits for a PubAck). */
    public void publishAuthorised(byte[] jsonPayload) throws IOException, JetStreamApiException {
        JetStream js = this.jetStream;
        if (js == null) {
            throw new IllegalStateException(
                    "NATS JetStream context not initialised -- readiness gate has not completed");
        }
        js.publish(SUBJECT, jsonPayload);
    }

    public boolean isConnected() {
        Connection nc = this.connection;
        return nc != null && nc.getStatus() == Connection.Status.CONNECTED;
    }

    @PreDestroy
    public void close() {
        Connection nc = this.connection;
        if (nc != null) {
            try {
                nc.close();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
    }
}
