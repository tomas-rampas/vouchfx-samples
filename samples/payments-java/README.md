# payments-java

A real Spring Boot 3.3 payments service, tested end-to-end with
[vouchfx](https://github.com/tomas-rampas/vouchfx): one HTTP request is followed all the way
through a SQL Server write, an outbound NATS JetStream event, and an outbound SMTP receipt
e-mail — in a single `.e2e.yaml` suite, against a real container topology. This is the sample's
Java entry in the set (alongside `orders-dotnet` and `inventory-python`) and the only one that
exercises SQL Server, NATS JetStream, and SMTP/Mailpit.

## What this demonstrates

A "hello world" REST sample stops at asserting an HTTP response. A real payments service keeps
working *after* it answers the request: it commits a database row, tells the rest of the system
the payment happened via an event, and lets the customer know by e-mail. A unit test — or a tool
that only speaks HTTP — cannot see any of that. This sample exists to prove vouchfx can:

- drive a **real containerised Java/Spring Boot service** (not a stub) through its public HTTP
  surface, including its own resilient startup sequence against slow-starting dependencies;
- assert a **side-effecting SQL Server write** landed correctly, with the row keyed by a value
  captured from the HTTP response;
- assert an **asynchronous NATS JetStream event** was published, via engine-owned RETRY polling
  (no author-written `sleep`) — and do so despite the specific ordering hazard JetStream
  publish-before-stream-exists creates (see "Design decision: JetStream stream ownership" below);
- assert the service sent a **real SMTP e-mail**, captured by Mailpit and matched on recipient
  and subject — again via engine-owned RETRY, not a fixed wait;
- and do all of this from **one coherent business-transaction narrative**, not four disconnected
  checks.

## Architecture

```
                                    ┌───────────────────────────────┐
                                    │     vouchfx orchestration      │
                                    │     (.NET Aspire topology)     │
                                    └───────────────┬─────────────────┘
                                                    │ starts / health-gates
                                                    ▼
 ┌───────────────┐   1. POST /payments    ┌──────────────────────┐
 │ vouchfx        │ ─────────────────────▶│    payments-api        │
 │ compiled       │   {orderId, amount,   │  (this sample's app)   │
 │ suite (CSX)    │    customerEmail}     └───────────┬─────────────┘
 │                │                                   │
 │                │   201 {id, orderId,               │ 2. INSERT INTO payments (…)
 │                │◀── amount, status}                 ▼
 │                │                          ┌──────────────────────┐
 │                │                          │      SQL Server         │
 │                │   2. db-assert.sqlserver │      (paydbdb)          │
 │                │─────────────────────────▶│    payments table       │
 │                │                          └──────────────────────┘
 │                │
 │                │                          ┌──────────────────────┐
 │                │   3. mq-expect.nats      │   NATS JetStream         │
 │                │─────────────────────────▶│  payments.authorised    │◀── 3. JetStream
 │                │        (RETRY)           │  stream: PAYMENTS_       │    publish (app)
 │                │                          │  AUTHORISED              │
 │                │                          └──────────────────────┘
 │                │
 │                │                          ┌──────────────────────┐
 │                │   4. mail-expect.smtp    │        Mailpit           │
 │                │─────────────────────────▶│    (SMTP capture)        │◀── 4. SMTP send
 │                │        (RETRY)           └──────────────────────┘        (app)
 └───────────────┘
```

`payments-api` runs as an ordinary container (`environment.services.payments-api`); SQL Server,
NATS, and Mailpit run as vouchfx-managed Aspire dependencies (`environment.dependencies`), each
of type `sqlserver`, `nats`, and `mailpit` respectively.

## The app (`app/`)

A single-module Maven project (`pom.xml`), Java 17, Spring Boot 3.3.13. No Lombok, no JPA/ORM —
one table, plain `JdbcTemplate`. Dependencies: `spring-boot-starter-web`,
`spring-boot-starter-jdbc`, `mssql-jdbc` (12.10.0.jre11), `io.nats:jnats` (2.25.3),
`spring-boot-starter-mail` (used only to pull in `jakarta.mail-api` + Angus Mail — see
`ReceiptMailSender`'s Javadoc for why Spring's own mail autoconfiguration is bypassed).

Configured entirely by environment variables (no `spring.mail.*`, no custom `application-*.yml`
profiles):

| Env var | Purpose |
| --- | --- |
| `SPRING_DATASOURCE_URL` / `_USERNAME` / `_PASSWORD` | Bound natively by Spring Boot's relaxed environment-variable binding to `spring.datasource.{url,username,password}`. |
| `NATS_URL` | full `nats://user:pass@host:port` connection URL (the managed NATS dependency is provisioned with credentials); read directly via `System.getenv` in `NatsPublisher`. |
| `SMTP_HOST` / `SMTP_PORT` | Read directly via `System.getenv` in `ReceiptMailSender` — deliberately not `SPRING_MAIL_*` (see that class's Javadoc). |

Behaviour:

- **Startup** (`ReadinessGate`, a Spring `ApplicationRunner`): retries the SQL Server schema
  check (`IF OBJECT_ID(...) IS NULL BEGIN CREATE TABLE ... END` — T-SQL has no `CREATE TABLE IF
  NOT EXISTS`) and the NATS connect + JetStream-stream-ensure step every 2s, with no hard
  timeout (see "Troubleshooting" for why), typically converging within the ~60s the brief
  targets. `GET /` returns `503 {"status":"starting"}` until both succeed, then
  `200 {"status":"ready"}` — **this is the exact contract the vouchfx health gate polls** before
  letting any step run. Requires `spring.datasource.hikari.initialization-fail-timeout: -1` (set
  in `application.yml`) so the autoconfigured `HikariDataSource` bean does not itself throw and
  crash the process before the retry loop ever runs.
- **`POST /payments`** `{orderId, amount, customerEmail}` → `201 {id, orderId, amount, status:
  "AUTHORISED"}`. Inserts the row, publishes `{id, orderId, amount, status}` (camelCase JSON) to
  the NATS JetStream subject `payments.authorised`, and sends a plain-text receipt e-mail
  (subject `Payment receipt <id>`, body containing the order id and amount) via `SMTP_HOST:
  SMTP_PORT` — best-effort, see "Troubleshooting".
- **`GET /payments/{id}`** → `200` row JSON, or `404` for an unknown (but validly-formed) UUID.
  A syntactically invalid id (not a UUID at all) instead yields `400`: Spring binds `{id}` to a
  `UUID` path variable, and a value that does not parse fails that bind — this is Spring's
  `@PathVariable UUID` conversion behaviour, not a check `PaymentController` performs itself.

### Design decision: JetStream stream ownership

Read `app/src/main/java/com/vouchfx/samples/payments/messaging/NatsPublisher.java`'s Javadoc for
the full rationale; summary: the engine's `mq-expect.nats` step provider
(`Vouchfx.Steps.MqExpect.Nats/MqExpectNatsProvider.cs` in the vouchfx engine repo) consumes via
an **ephemeral ordered JetStream consumer** that scans its stream from the start of the retained
log (`DeliverPolicy.All`), and that provider **does** create its stream idempotently — but only
the first time its own step actually executes, i.e. step 3, well after step 1 has already told
this application to publish. A JetStream publish issued before any stream captures the target
subject is unrecoverable (there is nothing to retroactively record it against), so this
application creates the *same* stream, over the *same* subject, during its own resilient startup
sequence, well before it can accept the first `POST /payments`. Both sides are pinned to the
identical literal stream name `PAYMENTS_AUTHORISED` — the suite's `mq-expect.nats` step sets
`stream: PAYMENTS_AUTHORISED` explicitly rather than relying on both the app and the provider
independently re-deriving the provider's uppercase/underscore stream-naming rule from the subject
string (a single typo in either derivation would otherwise silently split the stream in two).

### Design decision: `amount` is a JSON string on the wire, not a JSON number

`CreatePaymentRequest.amount` is a `String`, parsed to `BigDecimal` explicitly in
`PaymentController`, not bound as a `BigDecimal` field directly. This follows from how the vouchfx
DSL's `{placeholder}` substitution actually works: the suite's `http.rest` step supplies
`amount` via a YAML `body:` mapping, and YAML forces the placeholder to be written as a quoted
string scalar (`"{paymentAmount}"`) — a bare `{paymentAmount}` would parse as an empty YAML
flow-mapping, not a placeholder token. The `body:` mapping is JSON-serialised at compile time
*before* `{placeholder}` substitution runs (a runtime textual replace over the already-serialised
JSON template), so the wire value is always a JSON string such as `"amount":"49.99"`, never an
unquoted JSON number. Modelling `amount` as a `String` and parsing it explicitly sidesteps any
reliance on Jackson's string-to-number coercion leniency and works identically regardless of how
a caller (this suite, or anyone else) sends the value.

## The suite (`tests/payments.e2e.yaml`)

Four steps, one narrative — "a customer pays, and everything downstream reacts":

1. **`create-payment`** (`http.rest`, `POST /payments`) — places the payment. Expects `201` and
   captures `paymentId` from the response's `$.id`. This proves the REST surface accepted the
   request and returned the shape the rest of the suite depends on.
2. **`assert-payment-row`** (`db-assert.sqlserver`, target `paydb`) — proves the `POST` really
   persisted a row, not just a `201` with no side effect: queries `WHERE id = @id` with
   `{paymentId}` substituted in as the parameter value, and asserts `rowCount: 1` and
   `row: {status: AUTHORISED}`. Deliberately does not assert on `amount` — comparing a SQL
   Server `decimal(12,2)` column's stringified form against a hand-typed literal is a needless
   source of formatting mismatches (trailing zeros, culture) this sample has no reason to court.
3. **`assert-authorised-event`** (`mq-expect.nats`, target `bus`, subject `payments.authorised`,
   `stream: PAYMENTS_AUTHORISED`, `verifyMode: RETRY`, `timeout: 60s`) — proves the app published
   the domain event, matching `$.id == {paymentId}` via `match.json`. RETRY absorbs the small,
   variable delay between the `INSERT` and the event landing — no author-written `sleep`. See
   "Design decision: JetStream stream ownership" above for why `stream:` is pinned explicitly.
4. **`assert-receipt-email`** (`mail-expect.smtp`, target `mail`, `verifyMode: RETRY`,
   `timeout: 60s`) — proves the customer received the receipt, matching `to: {customerEmail}`
   (the same value used in step 1's request body) and `subject-contains: "Payment receipt"`. No
   `expect.count` is set, so the step passes on at least one matching message rather than
   asserting an exact count.

## Provider table

| Family | Provider | Tier | Package (version) | Reference |
| --- | --- | --- | --- | --- |
| `http` | `rest` | Core | Engine-shipped (pinned via [`ENGINE_PIN`](../../ENGINE_PIN)) | [vouchfx](https://github.com/tomas-rampas/vouchfx) |
| `db-assert` | `sqlserver` | Core | Engine-shipped (pinned via [`ENGINE_PIN`](../../ENGINE_PIN)) | [vouchfx](https://github.com/tomas-rampas/vouchfx) |
| `mq-expect` | `nats` | Core | Engine-shipped (pinned via [`ENGINE_PIN`](../../ENGINE_PIN)) | [vouchfx](https://github.com/tomas-rampas/vouchfx) |
| `mail-expect` | `smtp` | Core | Engine-shipped (pinned via [`ENGINE_PIN`](../../ENGINE_PIN)) | [vouchfx](https://github.com/tomas-rampas/vouchfx) |

## Exact provider fields used, and where each was verified

Every field below was checked against the actual provider source in the vouchfx engine repo
(`src/Providers/Core/**/*Provider.cs`) — its `SchemaFragment` (the JSON Schema actually enforced)
and its emitted-CSX `Emit`/helper logic — not just `docs/language-reference.md`, verifying every
field directly against the provider source rather than the per-provider example
suites (those are validated separately by the engine's own examples-compile CI gate):

| Step type | Fields used | Verified against |
| --- | --- | --- |
| `http.rest` | `target`, `method`, `path`, `body` (YAML mapping), `expect.status`, `capture` | `Vouchfx.Steps.Core.HttpRest/HttpRestModel.cs` + `HttpRestProvider.cs` — a YAML mapping/sequence `body` is JSON-serialised at `Bind` time and the resulting template's `{placeholder}` tokens are resolved at step-execution time (never pre-resolved) — the basis for the `amount`-as-string design decision above. |
| `db-assert.sqlserver` | `target`, `query`, `parameters`, `expect.rowCount`, `expect.row` | `Vouchfx.Steps.DbAssert.SqlServer/DbAssertSqlServerProvider.cs` — parameter values are bound via `SqlParameter`/`AddWithValue` (parameterised, never concatenated); `expect.row` values are compared via `.ToString()` (ordinal) against the first row only; the query TEXT itself only supports `{placeholder}` for **identifier** substitution (`ResolveIdentifier`, `[A-Za-z0-9_.]`-validated), which this suite does not use — `{paymentId}` here is a **parameter value** (`parameters.id`), bound safely via `AddWithValue`. |
| `mq-expect.nats` | `target`, `subject`, `stream`, `verifyMode: RETRY`, `timeout`, `match.json` | `Vouchfx.Steps.MqExpect.Nats/MqExpectNatsModel.cs` + `MqExpectNatsProvider.cs` — the emitted helper creates an **ephemeral ordered consumer** (`DeliverPolicy.All`, scanning from the start of the retained log) per RETRY attempt and never itself writes `Inconclusive` (the engine's RetryRunner converts a sustained `Fail` to `Inconclusive` on timeout); the provider's own `CreateStreamAsync` call is idempotent and tolerates NATS API error code 10058 ("stream name already in use") — the same code this sample's `NatsPublisher` tolerates. |
| `mail-expect.smtp` | `target`, `expect.match.to`, `expect.match.subject-contains` | `Vouchfx.Steps.MailExpect.Smtp/MailExpectSmtpModel.cs` + `MailExpectSmtpProvider.cs` — queries Mailpit's HTTP API (`GET /api/v1/messages?limit=100`, then `GET /api/v1/message/{ID}` only if `body-contains` is set, which this suite does not use), matches `to` case-insensitively against each address in the message's `To` list, and `subject-contains` ordinally; passes on `matched >= 1` when `expect.count` is absent (as here). |

## Engine contract

This suite exercises the engine's SUT-configuration surface: `environment.services.<name>.env`
(the `env:` block on `payments-api`) and the `${conn:<dependency>.<field>}` placeholder forms
(`.host`, `.port`, `.database`, `.username`, `.password`, plus the bare `${conn:bus}` full-URL
form used for `NATS_URL`). All of it has been validated **live, end-to-end**, against the
vouchfx engine commit pinned in [`../../ENGINE_PIN`](../../ENGINE_PIN) — the topology stands up
SQL Server, NATS, and Mailpit, `payments-api` receives its `env:` values and per-field
connection tokens, and all four suite steps pass against the real containers.

## How to run

Via the repository's sample runner:

```bash
scripts/run-sample.sh payments-java
```

```powershell
scripts\run-sample.ps1 payments-java
```

This: `docker build`s `app/` to the image referenced by
`environment.services.payments-api.image`, then hands `tests/payments.e2e.yaml` to the vouchfx
engine CLI so it provisions the Aspire topology (SQL Server + NATS + Mailpit + the
`payments-api` container) and executes the suite against it.

The equivalent manual steps, useful if you want finer-grained control over either half:

```bash
# 1. Build the image the suite's environment.services.payments-api references.
docker build -t vouchfx-samples-payments-java:local samples/payments-java/app

# 2. Run the suite (from the vouchfx engine checkout, with the dotnet global tool or CLI installed).
vouchfx run samples/payments-java/tests/payments.e2e.yaml
```

## Expected output

The full suite (`tests/payments.e2e.yaml`) contains 4 steps, all expected to pass:
`create-payment` → `assert-payment-row` → `assert-authorised-event` → `assert-receipt-email`.

Successful run output: **4 passed steps**; end-to-end wall-clock is dominated by topology startup (SQL Server container initialisation in particular, which can take a minute or more on first pull).

Artefact paths (when run via the sample runner):
- `out/payments-report.html` — interactive HTML report with step-by-step timeline, captures, assertions, and error details
- `out/payments-results.xml` — JUnit XML for IDE/CI integrations

## Troubleshooting

- **`GET /` stays `503` for a long time.** SQL Server's container is the usual cause: it
  routinely takes 15-45s to accept connections after `docker ps` reports it running, and during
  this delivery's own smoke test it took noticeably longer on a cold pull/first-init pass —
  `ReadinessGate` has **no hard timeout** precisely because of this variance (see its Javadoc);
  check `docker logs` for the SQL Server container to confirm it is still finishing its own
  startup/recovery sequence rather than the application being stuck.
- **The application crashes immediately instead of retrying.** Almost certainly
  `spring.datasource.hikari.initialization-fail-timeout` regressed away from `-1` in
  `application.yml` — without it, the autoconfigured `HikariDataSource` bean validates a
  connection eagerly during `ApplicationContext` startup and throws before `ReadinessGate` ever
  gets a chance to retry.
- **`mq-expect.nats` never matches, or matches a stale message from a previous run.** Check that
  `NatsPublisher.STREAM_NAME` (`PAYMENTS_AUTHORISED`) and the suite's `stream:` field on
  `assert-authorised-event` still agree — see "Design decision: JetStream stream ownership"
  above. Also remember `mq-expect.nats` scans its stream from the **start** of the retained log
  on every attempt (an ordered consumer, `DeliverPolicy.All`), so re-running this suite against a
  **shared, already-populated** `bus` dependency (rather than a fresh one per run) can produce a
  false pass against an old message; this is a documented engine-level constraint
  (`MqExpectNatsProvider.cs`'s "Shared-stream caution" comment), not specific to this sample.
- **The receipt e-mail never arrives / `mail-expect.smtp` times out.** `ReceiptMailSender` treats
  SMTP failure as best-effort by design (logs and returns after 3 attempts with a short backoff,
  rather than failing the customer-facing `POST /payments`) — check `docker logs` for the "Giving
  up sending receipt e-mail" line; if present, the fault is in reaching Mailpit (wrong
  `SMTP_HOST`/`SMTP_PORT`, or Mailpit not yet healthy), not in the suite's matching criteria.
- **`db-assert.sqlserver` reports a row-count or column mismatch.** Remember `expect.row` values
  are compared as `.ToString()` output (ordinal) against whatever `Microsoft.Data.SqlClient`
  returns for that column — this suite only asserts on `status` (a plain `nvarchar`) for exactly
  this reason; if you extend the query to assert on `amount` (a `decimal(12,2)`), expect the
  driver's default numeric-to-string formatting to matter.

## Key documents

- **[Engine blueprint](https://tomas-rampas.github.io/vouchfx/docs/01_Technical_Architecture_and_Engineering_Blueprint.html)** — the five-layer design, memory model, provider contract (frozen for v1.x), §5 Roslyn/memory, §13 provider architecture
- **[YAML DSL specification](https://tomas-rampas.github.io/vouchfx/docs/02_YAML_DSL_Specification_and_VSCode_Extension_Design.html)** — `.e2e.yaml` grammar, step families, capture/placeholder syntax, verifyMode
- **[Engine CONTRIBUTING.md](https://github.com/tomas-rampas/vouchfx/blob/main/CONTRIBUTING.md)** — how to implement a new provider, SDK contract (source)
- **[vouchfx-providers hub](https://tomas-rampas.github.io/vouchfx-providers/)** — community provider listings and the Vouched badge
