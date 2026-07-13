# Migrating to vouchfx

Three worked examples, each porting a genuine, realistic test asset onto vouchfx: a Postman smoke collection, a hand-rolled xUnit integration test, and a SpecFlow feature. Every example follows the same shape:

```
migrations/<name>/
├── source/    the genuine BEFORE artefact — a real Postman collection, a real .csproj that builds
├── ported/    the vouchfx AFTER — a runnable .e2e.yaml suite proving the same thing
└── README.md  a field-by-field mapping table, plus an honest "what does NOT map" section
```

| Migration | Source | What it proves |
| --- | --- | --- |
| [`from-postman/`](from-postman/) | A Postman Collection v2.1 export (two chained requests, `pm.test` assertions) | REST-only smoke coverage, `pm.test` → `expect`/`script.csharp`, collection variables → `capture`/`{placeholder}`, a Postman "secret"-type environment variable → `${secret:env/...}` |
| [`from-xunit/`](from-xunit/) | A small xUnit integration-test project (`HttpClient` + `Npgsql` + a hand-rolled Kafka poll loop) | Hand-rolled orchestration (env-var wiring, a `Task.Delay` poll loop) replaced by declarative steps and engine-owned `verifyMode: RETRY` |
| [`from-specflow/`](from-specflow/) | A SpecFlow 3.9.x project (genuine Gherkin + step definitions + a hand-rolled webhook listener) | The full four-family flow (REST + Postgres + Kafka + webhook), Given/When/Then intent carried by step `description` fields, `[BeforeScenario]` → `environment.seed` |

All three port the **same underlying system** — `samples/orders-dotnet/app`, the ASP.NET Core 8 order-confirmation service already exercised end-to-end by [`samples/orders-dotnet/tests/orders.e2e.yaml`](../samples/orders-dotnet/tests/orders.e2e.yaml) — so the only variable across the three examples is the *test asset being migrated*, not the system under test. Read `samples/orders-dotnet/README.md` first if you have not already; every idiom this tree relies on (the `@id::uuid` cast, `verifyMode: RETRY`, `{cb_container}`, `capture`) is explained there in full.

## Re-author, don't auto-convert

There is no tool in this tree — and none planned — that mechanically transliterates a Postman collection, an xUnit class, or a Gherkin feature into a `.e2e.yaml` file. That is a deliberate MVP framing decision, not a missing feature:

- **A Postman `pm.test` script, an xUnit `[Fact]`, and a SpecFlow step definition are all imperative code.** They can branch, loop, call arbitrary APIs, and assert in ways a declarative YAML schema fundamentally cannot represent 1:1. A mechanical converter would either silently drop capability or degrade every suite to the lowest common denominator all three source formats support — worse than either the original or a suite written by hand.
- **Porting a test is the right moment to ask what it is actually proving.** Every example in this tree is smaller and clearer than its source, not because vouchfx is more concise syntax for the same thing, but because re-authoring forces the question "what does this test need to be true?" instead of "what did the original code happen to do?" `migrations/from-xunit`'s ported suite has three steps; the original `[Fact]` needed several times as many lines to say the same thing, the bulk of it orchestration rather than assertion.
- **Each README's "what does NOT map" section is the honest part.** Arbitrary pre-request JavaScript, data-driven `[Theory]`/`ScenarioOutline` tables, deep structural body assertions, shared test-collection fixtures — none of these have a declarative vouchfx equivalent, and each README says so plainly rather than papering over the gap. Where vouchfx genuinely cannot express something declaratively, `script.csharp` is the documented escape hatch: unsandboxed, trusted C# with full access to the shared `Vars` context (§13 of the engine's blueprint) — exactly the same trust boundary the original imperative test code already had.

If you are migrating a real suite, expect the same shape of work these three examples show: read the original for intent, decide what actually needs proving, and write a suite that proves it — not a suite that mirrors the original's control flow.

## Running the migrations

All three ported suites, sequentially, via the migration runner (mirrors `scripts/run-sample.*`'s conventions — see its long comments on why the pattern below is written the way it is):

```bash
scripts/run-migrations.sh
```

```powershell
scripts\run-migrations.ps1
```

This bootstraps the pinned engine CLI if needed, builds the shared `vouchfx-samples-orders-dotnet:local` image once, sets `VOUCHFX_SAMPLES_ORDERS_API_KEY` (the dummy value `from-postman`'s `${secret:env/...}` header resolves — see that migration's README), and runs each of the three `ported/` suites in turn, non-zero exit if any fails. Reports land in `out/migrations-<name>-results.xml` / `out/migrations-<name>-report.html`.

Samples run strictly sequentially, even here: each suite stands up its own Aspire/Testcontainers topology via DCP, and running two topologies concurrently on one machine causes DCP port/network contention (see `docs/RUNNING.md`).

To run a single migration standalone, see the "Running this example" section at the foot of each migration's own README.
