# Migrating from SpecFlow

**Source:** [`source/Orders.Specs/`](source/Orders.Specs/) — a SpecFlow 3.9.x project: [`PlaceOrder.feature`](source/Orders.Specs/PlaceOrder.feature) in genuine Gherkin, [`PlaceOrderSteps.cs`](source/Orders.Specs/PlaceOrderSteps.cs) threading state through `ScenarioContext`, and [`CallbackListener.cs`](source/Orders.Specs/CallbackListener.cs) — a hand-rolled HTTP listener the scenario needs to observe the outbound webhook.

**Ported:** [`ported/place-order.e2e.yaml`](ported/place-order.e2e.yaml) — the same Given/When/Then narrative across all four step families (REST, Postgres, Kafka, webhook), the full flow `samples/orders-dotnet/tests/orders.e2e.yaml` also proves.

See [`../README.md`](../README.md) for the philosophy behind every migration in this tree: **re-author, don't auto-convert.**

## Why this project, specifically

SpecFlow is the classic "living documentation" choice for .NET teams who want business-readable scenarios backed by real step definitions — and a great many of those teams are migrating away from it today (SpecFlow itself is in maintenance mode; its community successor is [Reqnroll](https://reqnroll.net/)). This is exactly the audience most likely to be evaluating vouchfx: `PlaceOrder.feature` reads like a specification; `PlaceOrderSteps.cs` is where the actual integration-test plumbing — HTTP, Postgres, a hand-rolled Kafka poll, a hand-rolled webhook listener — accumulates underneath it, exactly as it does in a real SpecFlow suite.

**Build status: this source project compiles.** `dotnet build migrations/from-specflow/source/Orders.Specs` succeeds against this repository's pinned .NET 8 SDK (`global.json`) with SpecFlow 3.9.74 + SpecFlow.xUnit — the classic MSBuild code-behind generator runs cleanly and produces `PlaceOrder.feature.cs`. This repository's CI compile-checks it on every push (see `.github/workflows/samples-ci.yml`, job `migrations`); it is not *executed* there, for the same reason `migrations/from-xunit`'s source project is not — see that migration's README for why running the original requires a hand-assembled stack this repository deliberately does not ship.

## Field-by-field mapping

| SpecFlow element | vouchfx equivalent | Notes |
| --- | --- | --- |
| `Feature: ...` / `Scenario: ...` titles and the narrative prose under them | `metadata.description` + `metadata.name` | The suite-level summary of intent. |
| `Given` / `When` / `Then` step text | a step's `description` field | `place-order`'s description literally quotes the feature's `When`/`Then` lines it covers — see "What collapses" below. |
| Plain data-setup `Given` steps (no HTTP/DB/queue interaction) | nothing to write, or the suite's `variables:` block | `Given a customer wants to order 2 units of sku "WIDGET-SPEC-1"` only assigns local state in the original step definition; the ported suite inlines the same two values straight into `place-order`'s `body:`. |
| `ScenarioContext["orderId"] = ...` / reading it back in a later step | `capture` (writes into the shared `Vars` context) + `{orderId}` placeholder substitution | Same idea, engine-owned instead of author-owned: every step already shares one context: there is no separate "context object" to construct or inject. |
| `[BeforeScenario]` hook (here, `ResetFixturesAsync` — a hand-rolled `DELETE FROM orders WHERE sku = ...`) | `environment.seed` | See `ported/fixtures/reset-sku.sql` — applied after the whole topology (including `orders-api`'s own health gate, which only turns green once its table exists) is healthy, and before step 1 runs. |
| `IClassFixture<T>` / constructor-injected `HttpClient` lifetime, manually disposed | nothing to write | The engine owns the whole topology's lifecycle (start, health-gate, teardown) per suite run — there is no fixture class to write or dispose. |
| Hand-rolled `CallbackListener` (`HttpListener`, a `netsh http add urlacl` reservation, a `TaskCompletionSource`) | `webhook-listen.http` + `listener: cb` | One declarative step replaces an entire supporting class — see `CallbackListener.cs` for everything it stands in for. |
| Hand-rolled `ConsumerBuilder` + `while` + `Task.Delay` poll (near-identical to `migrations/from-xunit`'s test — see the comment in `PlaceOrderSteps.cs`) | `mq-expect.kafka` + `verifyMode: RETRY` | The same duplication point as the xUnit migration: this exact ~20 lines tends to get re-typed into every test project that needs to observe a Kafka side effect. |
| `dotnet test` via `SpecFlow.xUnit` | the vouchfx CLI (`scripts/run-sample.sh` / here, `scripts/run-migrations.sh`) | |

### What collapses

The feature's `When the customer places the order` and `Then the order is confirmed` are two separate Gherkin lines (and, in `PlaceOrderSteps.cs`, two separate step-definition methods) because that split reads well as documentation. In the ported suite they are **one** `http.rest` step: the HTTP response *is* both the action and its own immediate assertion (`expect.status: 201`), so there is nothing left for a second step to do. This is a deliberate simplification, not a gap — see `place-order`'s `description` field, which names both feature lines it covers.

## What does NOT map

- **`ScenarioOutline` / `Examples:` tables** (data-driven scenarios) have no direct declarative equivalent. The honest options are one `.e2e.yaml` file per case (each fully readable on its own, at the cost of duplication), or a `script.csharp` step that loops over a fixed set of inputs itself — vouchfx does not have a templated-scenario feature.
- **Arbitrary step-definition logic** beyond HTTP/DB/queue calls and simple `ScenarioContext` bookkeeping (e.g. a step that shells out to a CLI tool, or drives a UI) has no first-class step family. `script.csharp` is the escape hatch: unsandboxed, trusted C# with full `Vars` access (§13 of the engine's blueprint) — the same trust boundary a SpecFlow step definition already has.
- **`[BeforeTestRun]` / `[AfterTestRun]`** (process-wide, run-once-for-the-whole-assembly hooks) have no equivalent — every `.e2e.yaml` suite gets its own topology, by design (topological parity requires each suite to be independently reproducible; see `migrations/from-xunit/README.md` for the identical point about xUnit collection fixtures).
- **SpecFlow's Gherkin regex/cucumber-expression step matching** — the pattern-matched, reusable `[Given(@"...")]` text that lets many scenarios share one step definition — has no equivalent. A vouchfx step's `description` is a plain string for humans; it does not participate in any matching or reuse.

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
  run "$(pwd)/migrations/from-specflow/ported" --fail-on-env-error --fail-on-inconclusive
```

Expected result: **Pass**, 4 steps (`place-order`, `assert-order-row`, `assert-order-event`, `assert-webhook-callback`).
