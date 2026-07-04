package com.vouchfx.samples.payments.domain;

/**
 * Request body for {@code POST /payments}.
 *
 * <p><b>{@code amount} is deliberately a {@link String}, not a {@link java.math.BigDecimal}:</b>
 * the companion vouchfx suite (tests/payments.e2e.yaml) supplies this value via a
 * {@code {placeholder}} substitution inside an {@code http.rest} step's YAML {@code body:}
 * mapping. YAML forces such a placeholder to be written as a quoted string scalar (a bare
 * {@code {paymentAmount}} would be parsed as an empty YAML flow-mapping, not a placeholder
 * token), and the engine's substitution is a textual replace performed AFTER the body has
 * already been serialised to JSON -- so the wire value is always a JSON string, e.g.
 * {@code "amount":"49.99"}, never an unquoted JSON number. Accepting a {@link String} here
 * and parsing it explicitly in the controller sidesteps any reliance on Jackson's
 * string-to-number coercion leniency and works identically whether a caller sends the
 * amount quoted or unquoted.
 */
public record CreatePaymentRequest(String orderId, String amount, String customerEmail) {
}
