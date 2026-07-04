package com.vouchfx.samples.payments.mail;

import jakarta.mail.Message;
import jakarta.mail.MessagingException;
import jakarta.mail.Session;
import jakarta.mail.Transport;
import jakarta.mail.internet.InternetAddress;
import jakarta.mail.internet.MimeMessage;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.math.BigDecimal;
import java.util.Properties;
import java.util.UUID;

/**
 * Sends the plain-text payment-receipt e-mail via raw SMTP, no auth, no TLS (Mailpit).
 *
 * <p>Deliberately bypasses Spring Boot's {@code spring.mail.*} auto-configuration
 * ({@code MailSenderAutoConfiguration} / {@code JavaMailSender}): this application's
 * environment contract (see README.md) uses bare {@code SMTP_HOST} / {@code SMTP_PORT}
 * variables, mirroring {@code NATS_URL} rather than the {@code SPRING_MAIL_HOST} /
 * {@code SPRING_MAIL_PORT} names Spring's relaxed environment-variable binding would
 * require to populate {@code spring.mail.host} / {@code spring.mail.port}. Building a fresh
 * {@code jakarta.mail} {@link Session} directly from those two environment variables avoids
 * having to also document a second, Spring-flavoured set of variable names.
 * {@code spring-boot-starter-mail} is still a dependency purely to pull in the
 * {@code jakarta.mail-api} + Angus Mail implementation jars this class uses.
 */
@Component
public class ReceiptMailSender {

    private static final Logger log = LoggerFactory.getLogger(ReceiptMailSender.class);
    private static final String FROM_ADDRESS = "payments@vouchfx-samples.local";
    private static final int MAX_ATTEMPTS = 3;
    private static final long RETRY_BACKOFF_MILLIS = 250L;

    private final String smtpHost;
    private final String smtpPort;

    public ReceiptMailSender() {
        this.smtpHost = System.getenv("SMTP_HOST");
        this.smtpPort = System.getenv("SMTP_PORT");
    }

    /**
     * Sends the receipt. Best-effort: logs and returns rather than throwing on failure --
     * the suite's {@code mail-expect.smtp} step already tolerates the message arriving a
     * little after the HTTP response completes ({@code verifyMode: RETRY}), so a transient
     * SMTP hiccup should not fail the customer-facing {@code POST /payments} call.
     */
    public void sendReceipt(UUID paymentId, String orderId, BigDecimal amount, String customerEmail) {
        if (isBlank(smtpHost) || isBlank(smtpPort)) {
            log.error("SMTP_HOST/SMTP_PORT not configured; skipping receipt e-mail for payment {}", paymentId);
            return;
        }

        Properties props = new Properties();
        props.put("mail.smtp.host", smtpHost);
        props.put("mail.smtp.port", smtpPort);
        props.put("mail.smtp.auth", "false");
        props.put("mail.smtp.starttls.enable", "false");
        Session session = Session.getInstance(props);

        String subject = "Payment receipt " + paymentId;
        String body = "Order: " + orderId + System.lineSeparator()
                + "Amount: " + amount + System.lineSeparator()
                + "Payment ID: " + paymentId;

        for (int attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
            try {
                MimeMessage message = new MimeMessage(session);
                message.setFrom(new InternetAddress(FROM_ADDRESS));
                message.setRecipients(Message.RecipientType.TO, InternetAddress.parse(customerEmail));
                message.setSubject(subject);
                message.setText(body);
                Transport.send(message);
                log.info("Sent receipt e-mail for payment {} to {}", paymentId, customerEmail);
                return;
            } catch (MessagingException e) {
                log.warn("Attempt {}/{} to send receipt e-mail for payment {} failed: {}",
                        attempt, MAX_ATTEMPTS, paymentId, e.getMessage());
                if (attempt == MAX_ATTEMPTS) {
                    log.error("Giving up sending receipt e-mail for payment {}", paymentId, e);
                    return;
                }
                sleepQuietly(RETRY_BACKOFF_MILLIS);
            }
        }
    }

    private static void sleepQuietly(long millis) {
        try {
            Thread.sleep(millis);
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
        }
    }

    private static boolean isBlank(String value) {
        return value == null || value.isBlank();
    }
}
