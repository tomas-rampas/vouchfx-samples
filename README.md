# vouchfx-samples

[![Samples CI](https://github.com/tomas-rampas/vouchfx-samples/actions/workflows/samples-ci.yml/badge.svg?branch=main)](https://github.com/tomas-rampas/vouchfx-samples/actions/workflows/samples-ci.yml?query=branch%3Amain)
[![Docs](https://img.shields.io/badge/docs-GitHub_Pages-blue)](https://tomas-rampas.github.io/vouchfx-samples/)
[![License](https://img.shields.io/github/license/tomas-rampas/vouchfx-samples)](https://github.com/tomas-rampas/vouchfx-samples/blob/main/LICENSE)

Real-world working samples for [vouchfx](https://github.com/tomas-rampas/vouchfx) — the engine that compiles declarative `.e2e.yaml` integration tests into C#, orchestrates your full container topology with .NET Aspire, and proves a distributed system works end-to-end. Clone this repository, run one command, and watch vouchfx test a real polyglot system: REST API calls fanning out into database writes, broker events, cache entries, and outbound webhooks — all in one coherent business-transaction narrative, all proven end-to-end.

## The Sample Catalogue

Each sample is a **real service** (not a toy echo), with its own database, broker, or cache. The suite drives one complete business transaction through every hop. Browse the exact providers exercised and the technology pairing for each:

| Sample | Language / Stack | Transaction Under Test | vouchfx Providers Exercised |
|--------|------------------|------------------------|-----------------------------|
| **[orders-dotnet](samples/orders-dotnet/)** | ASP.NET Core 8 + C# | Customer places order → Postgres row → Kafka event → outbound webhook callback | `http.rest`, `db-assert.postgres`, `mq-expect.kafka`, `webhook-listen.http` |
| **[inventory-python](samples/inventory-python/)** | FastAPI + Python 3.12 | Create item → MySQL row + Redis cache entry → RabbitMQ event | `http.rest`, `db-assert.mysql`, `cache-assert.redis`, `mq-expect.rabbitmq` |
| **[payments-java](samples/payments-java/)** | Spring Boot 3.3 + Java 17 | Authorise payment → SQL Server row → NATS JetStream event → SMTP receipt email | `http.rest`, `db-assert.sqlserver`, `mq-expect.nats`, `mail-expect.smtp` |
| **[ledger-jsonrpc](samples/ledger-jsonrpc/)** | Node.js 22 + JSON-RPC 2.0 | Ledger transactions (REST) → Postgres row → Kafka event → independent worker role consuming an injected adjustment | `rpc.json-rpc` (Community), `db-assert.postgres`, `mq-publish.kafka`, `mq-expect.kafka`, `script.csharp` — **custom runner** |

Each sample's `README.md` walks through the transaction, the code, the suite design, and what success looks like.

**Migrating from an existing test estate?** [`migrations/`](migrations/) holds three worked porting examples — a Postman collection, a hand-rolled xUnit integration test, and a SpecFlow feature — each pairing the genuine before-artefact with a runnable `.e2e.yaml` port and a field-by-field mapping table. The guide is published at [Migrating to vouchfx](https://tomas-rampas.github.io/vouchfx-samples/docs/migrating.html); run all three ported suites with `scripts/run-migrations.sh` (or `.ps1`).

## Quick Start

**Prerequisites:** .NET 8 SDK (8.0.400+), Docker with Linux containers, Git. See [`docs/RUNNING.md`](docs/RUNNING.md) for the full list and background.

Two commands from the repository root:

```bash
# 1. Fetch and build the pinned vouchfx engine (one-time)
./scripts/bootstrap.sh

# 2. Build a sample's Docker image and run its suite
./scripts/run-sample.sh orders-dotnet
```

On Windows (PowerShell):

```powershell
.\scripts\bootstrap.ps1
.\scripts\run-sample.ps1 orders-dotnet
```

To run all four samples back-to-back:

```bash
./scripts/run-sample.sh all
```

Reports land in `out/`:

- `out/<sample>-results.xml` — JUnit XML (for IDE test-result integrations and CI)
- `out/<sample>-report.html` — self-contained interactive report; open directly in a browser

## How the Samples Configure the System Under Test

Each suite declares the services it tests and the infrastructure it needs in its `environment:` block. Here's an excerpt from the orders-dotnet sample:

```yaml
environment:
  services:
    orders-api:
      image: vouchfx-samples-orders-dotnet:local
      httpPort: 8080
      env:
        ConnectionStrings__orders: "${conn:ordersdb}"
        KAFKA_BOOTSTRAP: "${conn:broker}"

  dependencies:
    ordersdb:
      type: postgres
    broker:
      type: kafka
```

The engine resolves `${conn:<dependency>}` and `${conn:<dependency>.<field>}` tokens (e.g. `.host`, `.port`, `.database`, `.username`, `.password`) to the container-reachable network addresses at topology build time. This decouples the sample's suite from any hardcoded hostnames or ports, enabling the same suite to run identically against local Docker, a SaaS orchestrator, or on-premises Kubernetes. **Requires the vouchfx engine at or after the commit pinned in [`ENGINE_PIN`](ENGINE_PIN)** — consult that file and [`docs/RUNNING.md`](docs/RUNNING.md) for version compatibility.

## What "Proven" Means

The vouchfx engine separates **four** distinct verdicts — this is deliberate and is the single most important thing to understand when reading a test result. The full taxonomy, with exit-code mappings and what each verdict means for your product, is documented in the engine's [blueprint](https://tomas-rampas.github.io/vouchfx/docs/01_Technical_Architecture_and_Engineering_Blueprint.html) § 12.1. In brief:

- **Pass** — every assertion held; the system works as built.
- **Fail** — an assertion failed; a genuine defect exists in the code.
- **Environment Error** — infrastructure broke before the system under test was meaningfully exercised (a container failed to start, an image pull failed, a health check never turned green). This is not a code defect.
- **Inconclusive** — the engine could not determine correctness in time (a timeout, a network partition, an upstream event that never arrived). Not a verdict on the code itself.

Only `Fail` breaks the exit code. See [`docs/RUNNING.md`](docs/RUNNING.md) for the complete exit-code table and how to interpret each result.

## Directory Layout

```
.
|-- README.md                           (this file)
|-- CONTRIBUTING.md                     (how to add a new sample)
|-- LICENSE                             (Apache-2.0)
|-- ENGINE_PIN                          (the pinned vouchfx engine commit SHA)
|-- docs/
|   |-- RUNNING.md                      (prerequisites, quick start, reading results)
|   |-- migrating.md                    (the migration guide: Postman/xUnit/SpecFlow -> vouchfx)
|   `-- ...                             (other documentation)
|-- scripts/
|   |-- bootstrap.sh / bootstrap.ps1    (fetch and build the pinned engine)
|   |-- run-sample.sh / run-sample.ps1  (build a sample's image and run its suite)
|   |-- run-migrations.sh / .ps1        (run the three ported migration suites)
|   `-- ...
|-- migrations/
|   |-- from-postman/                   (Postman collection -> .e2e.yaml, source + ported + mapping)
|   |-- from-xunit/                     (xUnit integration test -> .e2e.yaml)
|   |-- from-specflow/                  (SpecFlow feature -> .e2e.yaml)
|   `-- README.md                       (the porting philosophy and how to run them)
|-- samples/
|   |-- orders-dotnet/
|   |   |-- app/                        (Dockerfile + ASP.NET Core service)
|   |   |-- tests/orders.e2e.yaml       (the test suite)
|   |   `-- README.md                   (sample documentation)
|   |-- inventory-python/
|   |   |-- app/                        (Dockerfile + FastAPI service)
|   |   |-- tests/inventory.e2e.yaml    (the test suite)
|   |   `-- README.md                   (sample documentation)
|   |-- payments-java/
|   |   |-- app/                        (Dockerfile + Spring Boot service)
|   |   |-- tests/payments.e2e.yaml     (the test suite)
|   |   `-- README.md                   (sample documentation)
|   |-- ledger-jsonrpc/
|   |   |-- app/                        (Dockerfile + Node.js service, dual-role)
|   |   |-- runner/                     (custom runner for Community providers)
|   |   |-- tests/ledger.e2e.yaml       (the test suite)
|   |   `-- README.md                   (sample documentation)
|   `-- ...
|-- out/                                (test results: HTML, JUnit XML)
|   `-- (generated after running samples)
`-- .vouchfx-src/                       (pinned engine source, created by bootstrap.sh)
    `-- (generated, not committed)
```

## Key Documents

### This Repository

- **[`README.md`](README.md)** — overview, catalogue, quick start (you are here)
- **[`docs/RUNNING.md`](docs/RUNNING.md)** — prerequisites, how to read results, CI notes
- **[`docs/migrating.md`](docs/migrating.md)** — porting Postman / xUnit / SpecFlow assets onto vouchfx, with the three worked examples in [`migrations/`](migrations/)
- **[`CONTRIBUTING.md`](CONTRIBUTING.md)** — how to add a new sample, quality bar, DCO sign-off
- **Per-sample READMEs:**
  - [`samples/orders-dotnet/README.md`](samples/orders-dotnet/README.md) — ASP.NET Core e2e flow, webhook listener design, database assertions
  - [`samples/inventory-python/README.md`](samples/inventory-python/README.md) — Python/FastAPI, MySQL + Redis + RabbitMQ integration, read-through cache proof
  - [`samples/payments-java/README.md`](samples/payments-java/README.md) — Spring Boot, SQL Server, NATS JetStream, SMTP email capture, stream-ownership design pattern
  - [`samples/ledger-jsonrpc/README.md`](samples/ledger-jsonrpc/README.md) — Node.js JSON-RPC 2.0, custom runner pattern for Community providers, multi-role containers, Kafka producer + consumer coordination

### vouchfx Engine

- **[Engine GitHub Repository](https://github.com/tomas-rampas/vouchfx)** — the system under test
- **[Project Website](https://tomas-rampas.github.io/vouchfx/)** — getting started guide, language reference, recipes, and architecture overview
- **[Engine CONTRIBUTING.md](https://github.com/tomas-rampas/vouchfx/blob/main/CONTRIBUTING.md)** — how to write a new provider
- **[Technical Architecture & Blueprint](https://tomas-rampas.github.io/vouchfx/docs/01_Technical_Architecture_and_Engineering_Blueprint.html)** — the five-layer design, memory model, Aspire integration, verdict taxonomy, provider contract
- **[YAML DSL Specification](https://tomas-rampas.github.io/vouchfx/docs/02_YAML_DSL_Specification_and_VSCode_Extension_Design.html)** — the `.e2e.yaml` grammar, step families, capture/placeholder syntax

### Related Repositories

- **[vouchfx-providers](https://tomas-rampas.github.io/vouchfx-providers/)** — the community provider hub: the registry of community providers and hub-hosted provider source. Providers can earn the maintainer-awarded Vouched badge after rubric review.
- **[vouchfx-telemetry-backend](https://tomas-rampas.github.io/vouchfx-telemetry-backend/)** — the optional telemetry aggregation service (aggregate run-metadata only: verdict counts, timings, tool/engine versions, under a privacy allowlist with 90-day retention default).

## Status

**Samples:** All four samples are validated live against local Docker and orchestrated end-to-end with vouchfx.

**Engine consumption:** vouchfx v1.0.0-alpha pre-releases are live on NuGet.org and GitHub. This repository **deliberately builds from source** at the pinned SHA in [`ENGINE_PIN`](ENGINE_PIN) for reproducibility and DCP binary path portability — the packaged CLI's embedded absolute paths only work on systems whose ~/.nuget/packages already holds matching aspire.hosting.orchestration versions. Building from source guarantees a self-sufficient CI run.

**Documentation:** British English throughout. Samples are living documentation: every `.e2e.yaml` file is a worked example of the YAML DSL, and every sample's README cross-references the engine's architecture blueprint and language reference so authors can verify their understanding against the canonical source.

## Licence

All contributions are made under the [Apache-2.0 licence](LICENSE). By contributing to this repository, you agree your contribution is licensed under Apache-2.0 and you have the right to licence it as such.

The vouchfx engine, the `Vouchfx.Sdk`, and all related documentation are also Apache-2.0 licensed, as are all provider tiers in the vouchfx-providers community hub.

---

**Questions?** Open an issue here for questions about samples or running the tests. For questions about the engine itself, vouchfx providers, or the DSL, see the [engine repository](https://github.com/tomas-rampas/vouchfx). Visit the [project website](https://tomas-rampas.github.io/vouchfx/) for getting-started guides and architecture documentation.

**Ready to contribute a sample?** Read [`CONTRIBUTING.md`](CONTRIBUTING.md) — we welcome real-world examples that showcase new technology pairings or integration patterns.
