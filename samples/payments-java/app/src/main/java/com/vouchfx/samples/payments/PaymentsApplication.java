package com.vouchfx.samples.payments;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Entry point for the payments-java vouchfx sample: a small Spring Boot service that
 * demonstrates a single business transaction crossing REST, SQL Server, NATS JetStream
 * and SMTP. See {@code README.md} (samples/payments-java/) for the full narrative.
 */
@SpringBootApplication
public class PaymentsApplication {

    public static void main(String[] args) {
        SpringApplication.run(PaymentsApplication.class, args);
    }
}
