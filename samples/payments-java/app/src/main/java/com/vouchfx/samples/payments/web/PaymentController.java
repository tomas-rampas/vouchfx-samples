package com.vouchfx.samples.payments.web;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.vouchfx.samples.payments.domain.CreatePaymentRequest;
import com.vouchfx.samples.payments.domain.Payment;
import com.vouchfx.samples.payments.domain.PaymentAuthorisedEvent;
import com.vouchfx.samples.payments.domain.PaymentCreatedResponse;
import com.vouchfx.samples.payments.mail.ReceiptMailSender;
import com.vouchfx.samples.payments.messaging.NatsPublisher;
import com.vouchfx.samples.payments.repository.PaymentRepository;
import com.vouchfx.samples.payments.startup.ReadinessGate;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * REST surface for the payments-java sample: {@code GET /} (readiness probe the vouchfx
 * engine health-gates on), {@code POST /payments} (the business transaction: INSERT +
 * JetStream publish + receipt e-mail) and {@code GET /payments/{id}}.
 */
@RestController
public class PaymentController {

    private static final Logger log = LoggerFactory.getLogger(PaymentController.class);
    private static final String STATUS_AUTHORISED = "AUTHORISED";

    private final ReadinessGate readinessGate;
    private final PaymentRepository paymentRepository;
    private final NatsPublisher natsPublisher;
    private final ReceiptMailSender receiptMailSender;
    private final ObjectMapper objectMapper;

    public PaymentController(
            ReadinessGate readinessGate,
            PaymentRepository paymentRepository,
            NatsPublisher natsPublisher,
            ReceiptMailSender receiptMailSender,
            ObjectMapper objectMapper) {
        this.readinessGate = readinessGate;
        this.paymentRepository = paymentRepository;
        this.natsPublisher = natsPublisher;
        this.receiptMailSender = receiptMailSender;
        this.objectMapper = objectMapper;
    }

    /** Health probe the vouchfx engine polls before running any suite step against this service. */
    @GetMapping("/")
    public ResponseEntity<StatusBody> health() {
        if (!readinessGate.isReady()) {
            return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body(new StatusBody("starting"));
        }
        return ResponseEntity.ok(new StatusBody("ready"));
    }

    @PostMapping("/payments")
    public ResponseEntity<PaymentCreatedResponse> createPayment(@RequestBody CreatePaymentRequest request) {
        BigDecimal amount = validate(request);
        UUID id = UUID.randomUUID();

        paymentRepository.insert(id, request.orderId(), amount, request.customerEmail(), STATUS_AUTHORISED);
        publishAuthorisedEvent(id, request.orderId(), amount);

        // Best-effort; see ReceiptMailSender's Javadoc for the retry/failure policy -- a
        // transient SMTP hiccup must not fail this customer-facing call.
        receiptMailSender.sendReceipt(id, request.orderId(), amount, request.customerEmail());

        return ResponseEntity.status(HttpStatus.CREATED)
                .body(new PaymentCreatedResponse(id, request.orderId(), amount, STATUS_AUTHORISED));
    }

    @GetMapping("/payments/{id}")
    public ResponseEntity<Payment> getPayment(@PathVariable UUID id) {
        return paymentRepository.findById(id)
                .map(ResponseEntity::ok)
                .orElseGet(() -> ResponseEntity.notFound().build());
    }

    private void publishAuthorisedEvent(UUID id, String orderId, BigDecimal amount) {
        PaymentAuthorisedEvent event = new PaymentAuthorisedEvent(id, orderId, amount, STATUS_AUTHORISED);
        try {
            byte[] payload = objectMapper.writeValueAsBytes(event);
            natsPublisher.publishAuthorised(payload);
        } catch (Exception e) {
            log.error("Failed to publish payments.authorised event for payment {}", id, e);
            throw new ResponseStatusException(
                    HttpStatus.INTERNAL_SERVER_ERROR, "Failed to publish payment-authorised event", e);
        }
    }

    /** Validates the request and returns the parsed decimal amount. See CreatePaymentRequest's Javadoc. */
    private static BigDecimal validate(CreatePaymentRequest request) {
        if (request == null || isBlank(request.orderId()) || isBlank(request.customerEmail())) {
            throw new ResponseStatusException(
                    HttpStatus.BAD_REQUEST, "orderId, amount and customerEmail are required");
        }
        BigDecimal amount;
        try {
            amount = new BigDecimal(request.amount().trim());
        } catch (NumberFormatException | NullPointerException e) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "amount must be a decimal number");
        }
        if (amount.signum() <= 0) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "amount must be greater than zero");
        }
        return amount;
    }

    private static boolean isBlank(String value) {
        return value == null || value.isBlank();
    }

    private record StatusBody(String status) {
    }
}
