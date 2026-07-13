# Migrating from a hand-rolled xUnit integration test

**Source:** [`source/OrdersApi.IntegrationTests/`](source/OrdersApi.IntegrationTests/) — a small, self-contained xUnit project: one `[Fact]` that places an order over plain `HttpClient`, then hand-rolls three separate verification techniques (an HTTP assertion, a direct `Npgsql` query, and a `Task.Delay`-based Kafka consumer poll loop) to prove it landed correctly.

**Ported:** [`ported/orders-integration.e2e.yaml`](ported/orders-integration.e2e.yaml) — the same three-part proof, expressed as three declarative steps against `samples/orders-dotnet/app`.

See [`../README.md`](../README.md) for the philosophy behind every migration in this tree: **re-author, don't auto-convert.**

## Why this test, specifically

This is the shape of "integration test" a team writes once a unit-test suite stops being enough: real `HttpClient`, a real database connection, and — because "the event fired" cannot be observed synchronously — a hand-rolled polling loop against a real Kafka consumer. It is not artificially padded; every line earns its place, and that is exactly the point. The **orchestration** code (environment wiring, the poll loop, cleanup) outweighs the **assertion** code (three `Assert.Equal` calls, one `Assert.True`) by a wide margin. vouchfx's whole reason to exist is to let the assertions stay and the orchestration disappear.

## Running the original test (not part of CI)

`source/OrdersApi.IntegrationTests` **compiles** (`dotnet build`) as part of this repository's own CI (see `.github/workflows/samples-ci.yml`, job `migrations`), proving the hand-rolled code above is genuine, working C# and not a strawman. It is **not executed** in CI — running it for real requires you to already have stood up exactly the stack vouchfx would otherwise stand up for you:

```bash
# 1. Start Postgres, Kafka, and the orders-dotnet app yourself (docker compose,
#    manual `docker run`, or your own harness — there is no compose file in this
#    directory on purpose: writing one *is* the work this migration ports away).
# 2. Point the test at it:
export ORDERS_API_BASE_URL=http://localhost:8080
export ORDERS_DB_CONNECTION_STRING="Host=localhost;Port=5432;Username=postgres;Password=postgres;Database=orders"
export KAFKA_BOOTSTRAP=localhost:9092

dotnet test migrations/from-xunit/source/OrdersApi.IntegrationTests
```

Three environment variables, a database migration/schema step the app happens to self-manage (`CREATE TABLE IF NOT EXISTS`, see `samples/orders-dotnet/app/DatabaseInitializer.cs`), and a topology you assemble and tear down by hand. Compare with the ported suite's `environment:` block, which the engine owns end to end.

## Field-by-field mapping

| xUnit element | vouchfx equivalent | Notes |
| --- | --- | --- |
| One `.e2e.yaml` file (a scenario) | `[Fact]` | A suite's ordered `steps:` list is the direct analogue of one test method's body. |
| `IAsyncLifetime.InitializeAsync` reading `ORDERS_API_BASE_URL` / `ORDERS_DB_CONNECTION_STRING` / `KAFKA_BOOTSTRAP` from the process environment | `environment.services` / `environment.dependencies` | vouchfx stands the topology up itself and resolves service addresses / connection strings automatically (`${conn:ordersdb}`, Aspire service discovery) — there is nothing left for the suite to configure. |
| The docker-compose/manual setup the test silently assumes is already running | the `environment` block | The engine owns the whole container lifecycle — start, health-gate, teardown — **per suite run**, not as separate out-of-band infrastructure the test trusts to exist. |
| `HttpClient.PostAsJsonAsync(...)` + `Assert.Equal(HttpStatusCode.Created, ...)` | `http.rest` step + `expect.status` | |
| Hand-rolled `NpgsqlConnection` / `NpgsqlCommand` / `NpgsqlDataReader` + `Assert.Equal` on each column | `db-assert.postgres` step (`query`, `parameters`, `expect.row`) | |
| Hand-rolled `ConsumerBuilder` + `while` loop + `Task.Delay` poll | `mq-expect.kafka` + `verifyMode: RETRY` | Engine-owned polling with bounded exponential backoff — see `docs/RUNNING.md` for the verdict this produces on a genuine timeout (`Inconclusive`, not `Fail`). |
| `IAsyncLifetime.DisposeAsync` disposing the `HttpClient` / closing the consumer | nothing to write | The engine owns every resource's lifecycle; there is no teardown method to remember. |
| `dotnet test` | the vouchfx CLI (`scripts/run-sample.sh` / here, `scripts/run-migrations.sh`) | |

## What does NOT map

- **Arbitrary setup/teardown logic** beyond seeding SQL and starting containers — e.g. calling an internal admin API to provision a tenant before the test runs — has no first-class `environment` field. Reach for a `script.csharp` step (the escape hatch), or, if it genuinely needs to happen before the topology's own health gate, raise it as a feature request against the engine (this repository does not modify the engine — see `CONTRIBUTING.md`).
- **Shared test-collection fixtures** (`[Collection]` / `ICollectionFixture<T>`, expensive setup shared across many `[Fact]`s) have no equivalent. Each `.e2e.yaml` file gets its own topology — by design: topological parity (a suite runs unchanged local/SaaS/CI) requires every suite to be independently reproducible, not dependent on another suite having already run in the same process.
- **Data-driven `[Theory]`/`[InlineData]` tests** have no direct declarative equivalent — the honest answer is one `.e2e.yaml` file per case, or a `script.csharp` step that loops over a fixed set of inputs itself (see `migrations/from-specflow/README.md` for the identical point about SpecFlow's `ScenarioOutline`).

## Running this example

Via the repository's migration runner (builds the shared `orders-dotnet` image and runs all three ported suites):

```bash
scripts/run-migrations.sh
```

```powershell
scripts\run-migrations.ps1
```

Or standalone:

```bash
# Note: dotnet run --project sets the launched process's working directory to the
# CLI project's own directory, not your shell's — pass an absolute suite path (as
# scripts/run-migrations.* does) rather than a relative one.
dotnet run --project .vouchfx-src/src/Cli/Vouchfx.Cli/Vouchfx.Cli.csproj -c Release -- \
  run "$(pwd)/migrations/from-xunit/ported" --fail-on-env-error --fail-on-inconclusive
```

Expected result: **Pass**, 3 steps (`place-order`, `assert-order-row`, `assert-order-event`).
