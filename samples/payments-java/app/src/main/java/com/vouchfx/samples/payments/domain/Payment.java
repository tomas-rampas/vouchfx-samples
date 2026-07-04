package com.vouchfx.samples.payments.domain;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

/** Full persisted representation of a payment row, returned by {@code GET /payments/{id}}. */
public record Payment(
        UUID id,
        String orderId,
        BigDecimal amount,
        String customerEmail,
        String status,
        Instant createdAt) {
}
