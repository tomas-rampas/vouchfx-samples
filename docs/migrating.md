# Migrating to vouchfx

Three worked examples, each porting a genuine, realistic test asset onto vouchfx: a Postman smoke collection, a hand-rolled xUnit integration test, and a SpecFlow feature. All three live in [`migrations/`](https://github.com/tomas-rampas/vouchfx-samples/tree/main/migrations) and port the same underlying system — `samples/orders-dotnet/app`, the ASP.NET Core 8 order-confirmation service already exercised end-to-end by [the orders-dotnet sample](../samples/orders-dotnet/README.md) — so the only variable across the three examples is the *test asset being migrated*, not the system under test.

## Re-author, don't auto-convert

There is no tool here — and none planned — that mechanically transliterates a Postman collection, an xUnit class, or a Gherkin feature into a `.e2e.yaml` file. That is a deliberate framing decision, not a missing feature:

- A Postman `pm.test` script, an xUnit `[Fact]`, and a SpecFlow step definition are all imperative code. They can branch, loop, call arbitrary APIs, and assert in ways a declarative YAML schema fundamentally cannot represent one-to-one. A mechanical converter would either silently drop capability or degrade every suite to the lowest common denominator all three source formats support — worse than either the original or a suite written by hand.
- Porting a test is the right moment to ask what it is actually proving. Every ported suite in `migrations/` is smaller and clearer than its source, not because vouchfx is more concise syntax for the same thing, but because re-authoring forces the question "what does this test need to be true?" instead of "what did the original code happen to do?"
- Each worked example's README carries an honest "what does NOT map" section — arbitrary pre-request JavaScript, data-driven test tables, deep structural body assertions, shared test-collection fixtures — rather than papering over the gap. Where vouchfx genuinely cannot express something declaratively, `script.csharp` is the documented escape hatch: unsandboxed, trusted C# with full access to the shared execution context, exactly the same trust boundary the original imperative test code already had.

## From Postman

**Source:** a Postman Collection v2.1 export — two chained requests (`POST /orders`, then `GET /orders/{{orderId}}`), each with a `pm.test` script.
**Ported:** [`migrations/from-postman/ported/orders-smoke.e2e.yaml`](https://github.com/tomas-rampas/vouchfx-samples/blob/main/migrations/from-postman/ported/orders-smoke.e2e.yaml).

| Postman element | vouchfx equivalent |
| --- | --- |
| `item[].request` (method/url/header/body) | an `http.rest` step (`target`, `method`, `path`, `headers`, `body`) |
| `pm.test("Status code is …", …)` | `expect.status` |
| `pm.test(...)` deep JSON-body assertion | capture the field, then assert it in a `script.csharp` step — `expect` supports only a status-code check |
| `pm.collectionVariables.set/get(...)` | `capture` (writes into the shared execution context) + `{placeholder}` substitution |
| `{{baseUrl}}` swapped per environment | not needed — vouchfx resolves the running container's address itself, via Aspire service discovery |
| a `"type": "secret"` environment variable | `${secret:env/...}`, resolved at step-execution time, never baked into the compiled suite |

**What does not map:** arbitrary pre-request JavaScript (→ `script.csharp`), `newman run --folder` (→ `metadata.tags` + tag selection), Postman's dynamic variables (`{{$guid}}`), and deep structural body assertions. See the [full README](https://github.com/tomas-rampas/vouchfx-samples/blob/main/migrations/from-postman/README.md) for the complete account.

## From xUnit

**Source:** a small xUnit integration-test project — one `[Fact]` that places an order over `HttpClient`, then hand-rolls a Postgres query and a `Task.Delay`-based Kafka consumer poll loop.
**Ported:** [`migrations/from-xunit/ported/orders-integration.e2e.yaml`](https://github.com/tomas-rampas/vouchfx-samples/blob/main/migrations/from-xunit/ported/orders-integration.e2e.yaml).

| xUnit element | vouchfx equivalent |
| --- | --- |
| One `.e2e.yaml` file | `[Fact]` |
| `IAsyncLifetime.InitializeAsync` reading base-URL/connection-string/broker env vars | `environment.services` / `environment.dependencies` — the engine resolves these automatically |
| Hand-rolled compose/env scaffolding the test assumes is already running | the `environment` block — the engine owns the whole container lifecycle per suite run |
| `HttpClient.PostAsJsonAsync` + `Assert.Equal` | `http.rest` + `expect.status` |
| Hand-rolled `NpgsqlConnection`/`NpgsqlCommand`/`NpgsqlDataReader` + assertions | `db-assert.postgres` (`query`, `parameters`, `expect.row`) |
| Hand-rolled `ConsumerBuilder` + `while` + `Task.Delay` poll | `mq-expect.kafka` + `verifyMode: RETRY` — engine-owned polling with bounded backoff |

**What does not map:** arbitrary setup/teardown beyond seeding SQL and starting containers (→ `script.csharp`), shared `[Collection]` fixtures across `[Fact]`s (each suite gets its own topology by design), and data-driven `[Theory]`/`[InlineData]` (→ one file per case, or a `script.csharp` loop). See the [full README](https://github.com/tomas-rampas/vouchfx-samples/blob/main/migrations/from-xunit/README.md).

## From SpecFlow

**Source:** a SpecFlow 3.9.x project — genuine Gherkin (`PlaceOrder.feature`) plus step definitions threading state through `ScenarioContext`, including a hand-rolled HTTP listener to observe an outbound webhook.
**Ported:** [`migrations/from-specflow/ported/place-order.e2e.yaml`](https://github.com/tomas-rampas/vouchfx-samples/blob/main/migrations/from-specflow/ported/place-order.e2e.yaml) — the full four-family flow (REST, Postgres, Kafka, webhook).

| SpecFlow element | vouchfx equivalent |
| --- | --- |
| `Feature:`/`Scenario:` narrative | `metadata.description` + `metadata.name` |
| `Given`/`When`/`Then` step text | a step's `description` field |
| `ScenarioContext["x"] = …` / reading it back | `capture` + `{placeholder}` substitution |
| `[BeforeScenario]` hook (a hand-rolled cleanup `DELETE`) | `environment.seed` |
| `IClassFixture`-style client lifetime | nothing to write — the engine owns the topology's lifecycle |
| a hand-rolled `HttpListener`-based webhook receiver | `webhook-listen.http` — one declarative step |

**What does not map:** `ScenarioOutline`/`Examples:` tables (→ one file per case, or a `script.csharp` loop), arbitrary step-definition logic beyond HTTP/DB/queue calls (→ `script.csharp`), `[BeforeTestRun]`/`[AfterTestRun]` process-wide hooks (every suite gets its own topology), and Gherkin's regex-based step reuse. See the [full README](https://github.com/tomas-rampas/vouchfx-samples/blob/main/migrations/from-specflow/README.md).

## Running the migrations

```bash
scripts/run-migrations.sh
```

```powershell
scripts\run-migrations.ps1
```

Builds the shared `orders-dotnet` image once, then runs all three `migrations/*/ported` suites sequentially through the pinned vouchfx engine CLI — the same conventions as `scripts/run-sample.*` (see [Running the samples](RUNNING.md)). Reports land in `out/migrations-<name>-results.xml` / `out/migrations-<name>-report.html`.

See the [`migrations/` tree on GitHub](https://github.com/tomas-rampas/vouchfx-samples/tree/main/migrations) for the full source, ported suites, and per-migration READMEs.
