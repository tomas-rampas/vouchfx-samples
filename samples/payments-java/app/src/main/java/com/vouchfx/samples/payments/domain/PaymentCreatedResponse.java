package com.vouchfx.samples.payments.domain;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * Response body for {@code POST /payments} — {@code 201 Created} with
 * {@code {id, orderId, amount, status}}. The vouchfx suite's {@code http.rest} step
 * captures {@code $.id} into {@code paymentId} for use by later steps.
 */
public record PaymentCreatedResponse(UUID id, String orderId, BigDecimal amount, String status) {
}
