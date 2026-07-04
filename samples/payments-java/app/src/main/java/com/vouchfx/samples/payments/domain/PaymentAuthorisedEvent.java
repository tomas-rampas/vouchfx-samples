package com.vouchfx.samples.payments.domain;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * The JSON payload published to the {@code payments.authorised} NATS JetStream subject
 * (field names match the vouchfx suite's {@code mq-expect.nats} JSONPath match on
 * {@code $.id} — see tests/payments.e2e.yaml).
 */
public record PaymentAuthorisedEvent(UUID id, String orderId, BigDecimal amount, String status) {
}
