package com.vouchfx.samples.payments.repository;

import com.vouchfx.samples.payments.domain.Payment;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * SQL Server access for the {@code payments} table via a plain {@link JdbcTemplate}
 * (no JPA/Hibernate — a single table with a handful of columns does not warrant an ORM
 * for this sample).
 */
@Repository
public class PaymentRepository {

    /**
     * T-SQL has no {@code CREATE TABLE IF NOT EXISTS}; the {@code IF OBJECT_ID(...) IS NULL}
     * guard is the standard idempotent equivalent for SQL Server. Column shape matches the
     * sample's design brief exactly: {@code id uniqueidentifier primary key, order_id
     * nvarchar(64) not null, amount decimal(12,2) not null, customer_email nvarchar(255)
     * not null, status nvarchar(32) not null, created_at datetime2 default sysutcdatetime()}.
     */
    private static final String CREATE_TABLE_SQL = """
            IF OBJECT_ID(N'dbo.payments', N'U') IS NULL
            BEGIN
                CREATE TABLE dbo.payments (
                    id UNIQUEIDENTIFIER NOT NULL PRIMARY KEY,
                    order_id NVARCHAR(64) NOT NULL,
                    amount DECIMAL(12,2) NOT NULL,
                    customer_email NVARCHAR(255) NOT NULL,
                    status NVARCHAR(32) NOT NULL,
                    created_at DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
                )
            END
            """;

    private static final String INSERT_SQL = """
            INSERT INTO dbo.payments (id, order_id, amount, customer_email, status)
            VALUES (?, ?, ?, ?, ?)
            """;

    private static final String SELECT_BY_ID_SQL = """
            SELECT id, order_id, amount, customer_email, status, created_at
            FROM dbo.payments
            WHERE id = ?
            """;

    private final JdbcTemplate jdbcTemplate;

    public PaymentRepository(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    /**
     * Idempotently ensures the {@code payments} table exists. Called from the resilient
     * startup retry loop ({@code ReadinessGate}) — throws on any connectivity failure so the
     * caller can retry; never called on the request path.
     */
    public void ensureSchema() {
        jdbcTemplate.execute(CREATE_TABLE_SQL);
    }

    public void insert(UUID id, String orderId, BigDecimal amount, String customerEmail, String status) {
        jdbcTemplate.update(INSERT_SQL, ps -> {
            // mssql-jdbc accepts java.util.UUID directly via setObject for a
            // uniqueidentifier column (transferred as its string form over the wire).
            ps.setObject(1, id);
            ps.setString(2, orderId);
            ps.setBigDecimal(3, amount);
            ps.setString(4, customerEmail);
            ps.setString(5, status);
        });
    }

    public Optional<Payment> findById(UUID id) {
        List<Payment> rows = jdbcTemplate.query(
                SELECT_BY_ID_SQL,
                ps -> ps.setObject(1, id),
                (rs, rowNum) -> new Payment(
                        rs.getObject("id", UUID.class),
                        rs.getString("order_id"),
                        rs.getBigDecimal("amount"),
                        rs.getString("customer_email"),
                        rs.getString("status"),
                        toInstant(rs.getTimestamp("created_at"))));
        return rows.stream().findFirst();
    }

    private static Instant toInstant(Timestamp timestamp) {
        return timestamp == null ? null : timestamp.toInstant();
    }
}
