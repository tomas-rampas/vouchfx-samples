# Running the samples

This page covers what you need installed, the two-command quick start, how to read a run's result, and what CI does differently from your machine.

## Prerequisites

- **Operating system:** Windows, macOS, or Linux. `scripts/*.sh` and `scripts/*.ps1` are feature-parity pairs — use whichever matches your shell.
- **.NET 8 SDK**, version 8.0.400 or later (`global.json` pins the exact minimum and enables `rollForward: latestFeature`). Get it from <https://dotnet.microsoft.com/download/dotnet/8.0>.
- **Docker**, with **Linux containers** (on Windows, that means Docker Desktop's WSL2 backend, not Windows containers). The engine orchestrates every sample's dependencies — Postgres, Kafka, SQL Server, and so on — as containers via .NET Aspire + Testcontainers; nothing here runs against infrastructure you install by hand.
- **Git**, reachable on `PATH` (used to shallow-fetch the pinned engine commit).
- **~8 GB of free RAM** for the heaviest sample. Aspire brings up the sample's own service(s) plus its managed dependencies (a database, a broker, etc.) all at once; budget accordingly if you're also running other containers.
- **Network access to GitHub and your container registry on first run.** The first `scripts/bootstrap.*` fetches the engine source; the first `scripts/run-sample.*` pulls the dependency images the chosen sample declares (Postgres, Kafka, SQL Server, ...). Both are cached afterwards — subsequent runs are offline-capable except for image/engine updates.

The vouchfx engine CLI is published as pre-release packages on NuGet.org (`dotnet tool install --global vouchfx --prerelease`). This repository **deliberately builds the engine from source** at a pinned commit to preserve reproducibility and avoid DCP binary path portability issues that affect pre-built packages. See [`ENGINE_PIN`](../ENGINE_PIN) for the exact commit and design rationale.

## Quick start

Two commands, from the repository root:

```bash
# 1. Fetch the pinned engine commit and build its CLI (one-time, or after bumping ENGINE_PIN)
./scripts/bootstrap.sh

# 2. Build a sample's image and run its suite
./scripts/run-sample.sh orders-dotnet
```

On Windows (PowerShell):

```powershell
.\scripts\bootstrap.ps1
.\scripts\run-sample.ps1 orders-dotnet
```

Run every sample, one at a time (`all` is intentionally sequential — see [Why samples don't run concurrently](#why-samples-dont-run-concurrently-on-one-machine) below):

```bash
./scripts/run-sample.sh all
```

`scripts/run-sample.*` calls `scripts/bootstrap.*` automatically the first time (whenever `.vouchfx-src/` is missing), so a completely fresh clone only needs step 2.

Reports land in `out/`:

- `out/<sample>-results.xml` — JUnit XML (for IDE/CI test-result integrations)
- `out/<sample>-report.html` — a self-contained HTML report, open it directly in a browser

## What a passing run looks like

vouchfx separates **four** outcomes, not two — this is deliberate and is the single most important thing to understand when reading a result:

| Verdict | Meaning | Breaks the `run-sample.*` exit code? |
|---|---|---|
| **Pass** | The suite ran and every assertion held. | No — exit `0`. |
| **Fail** | The suite ran and something the suite asserted was actually wrong — a genuine defect. | **Yes — exit `1`, always.** This is the only outcome that represents a real bug. |
| **EnvironmentError** | Infrastructure broke before the system under test was meaningfully exercised — a container failed to start, an image pull failed, a health check never turned green. | Yes here — exit `3`. (`run-sample.*` always passes `--fail-on-env-error`, so this repository treats infra breakage as CI-worthy, unlike the engine's own permissive default.) |
| **Inconclusive** | The engine could not determine correctness in time — a timeout, a network partition that outlasted its grace period, an upstream event that never arrived. | Yes here too — exit `4` (`run-sample.*` also always passes `--fail-on-inconclusive`). |

Full exit code table, as implemented by the engine CLI:

| Exit code | Meaning |
|---|---|
| `0` | Success — the suite passed, or produced only EnvironmentError/Inconclusive results (not applicable here, since `run-sample.*` opts in to gating on both). |
| `1` | At least one scenario produced a genuine `Fail` verdict. |
| `2` | A usage error — bad arguments, missing suite path; the suite never ran. |
| `3` | Aggregate verdict was `EnvironmentError` (infrastructure broke; the system under test was never properly exercised). |
| `4` | Aggregate verdict was `Inconclusive` (timeout, or the engine otherwise could not decide). |

**Only a `Fail`/exit-`1` result means "something in this sample is broken."** An exit `3` means Docker, the network, or a dependency image is the problem — not the sample's code. An exit `4` usually means the suite's timeouts are too tight for the machine it ran on, or a genuinely flaky race in the sample's own service. Treat `3` and `4` as "investigate the environment," and `1` as "investigate the code," starting from the HTML report's step-by-step timeline.

## Why samples don't run concurrently on one machine

Each suite brings up its own topology through .NET Aspire's orchestrator (DCP). Running two topologies at once on one host causes DCP port/network contention — the symptoms are usually a spurious `EnvironmentError` with a health-gate timeout that has nothing to do with either sample's actual code. `scripts/run-sample.* all` therefore always runs samples one after another, never in parallel, regardless of how many CPU cores are available.

## CI notes

`.github/workflows/samples-ci.yml` runs on every push and pull request to `main`, plus manual dispatch. It uses a **matrix of separate runners** — one per sample — rather than running all three on one machine:

- Each matrix job independently checks out the repo, sets up the pinned .NET SDK, bootstraps the pinned engine commit, and runs exactly one sample via `scripts/run-sample.sh <sample>`.
- Because each sample gets its own runner, there's no DCP contention between samples in CI even though they execute at the same time — the sequential constraint above is about *one machine*, not about the samples being inherently unable to run in parallel.
- `fail-fast: false` — one sample's failure doesn't cancel the others; you get a complete picture of all three every time.
- Every job uploads its `out/` directory as an artifact (`reports-<sample>`) regardless of outcome (`if: always()`), so you can open the HTML report for a failed CI run without reproducing it locally first.
- The job timeout is generous (25 minutes) to comfortably cover image pulls, Aspire/DCP startup (roughly 20 seconds per managed resource), and the heavier samples' dependencies (e.g. SQL Server) — a run taking the full 25 minutes is itself worth investigating, but isn't expected in the normal case.

If a sample fails only in CI and not locally, the most common causes are: a cold image cache (first pull is slow — re-run), or a timeout tuned for a faster local machine than the CI runner (adjust the suite's `timeout`/`verifyMode: RETRY` backoff, not the CI job timeout).
