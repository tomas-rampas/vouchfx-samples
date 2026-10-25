# Running the samples

This page covers what you need installed, the two-command quick start, how to read a run's result, and what CI does differently from your machine.

## Prerequisites

- **Operating system:** Windows, macOS, or Linux. Use `scripts/*.sh` with Bash or `scripts/*.ps1` with PowerShell 7 or later.
- **.NET 8, 9 or 10 SDK**, with 8.0.424 as the minimum. Current sample source keeps `net8.0` assets and enables major runtime roll-forward; `global.json` prefers .NET 8 and permits a higher SDK major when it is absent. The pinned engine checkout and installed CLI retain the SDK/runtime requirements of their selected revision or release; older candidates can still require .NET 8 alongside a newer SDK. Get .NET from <https://dotnet.microsoft.com/download/dotnet>.
- **Docker**, with **Linux containers** (on Windows, that means Docker Desktop's WSL2 backend, not Windows containers). Inline suites use .NET Aspire + Testcontainers; the Compose variant uses its selected native adapter to own the application and dependencies; nothing here runs against infrastructure you install by hand.
- **Git**, reachable on `PATH`, for source mode (used to shallow-fetch the pinned engine commit).
- **~8 GB of free RAM** for the heaviest sample. Aspire brings up the sample's own service(s) plus its managed dependencies (a database, a broker, etc.) all at once; budget accordingly if you're also running other containers.
- **Network access to GitHub and your container registry on first run.** The first `scripts/bootstrap.*` fetches the engine source; the first `scripts/run-sample.*` pulls the dependency images the chosen sample declares (Postgres, Kafka, SQL Server, ...). Both are cached afterwards — subsequent runs are offline-capable except for image/engine updates.

These runners default to a source build at the commit selected in [`ENGINE_PIN`](../ENGINE_PIN). See the [Core 1.2.0 source validation record](validation/core-1.2.0-source-validation-2026-10-22.md) for current source results and the [Core 1.2.0 installed acceptance record](validation/core-1.2.0-installed-acceptance-2026-10-22.md) for official CLI results. The [Core 1.0.7 source](validation/core-1.0.7-source-validation-2026-10-17.md), [Core 1.0.7 installed](validation/core-1.0.7-installed-acceptance-2026-10-17.md) and [Core 1.0.6](validation/core-1.0.6-acceptance.md) records preserve historical evidence. `ledger-jsonrpc` uses its custom source runner. Source and installed-package runs remain separate evidence.

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

Both runners invoke a sample's optional `setup.sh` / `setup.ps1` before building or running it.
Setup failure stops that sample. A sample without `app/`, such as `kafka-mtls`, skips the image build
and runs its suite against the containers declared in `environment:`.

Run all six samples sequentially in source mode (see [Why samples don't run concurrently](#why-samples-dont-run-concurrently-on-one-machine) below). Supply a fresh disposable credential for the Compose variant:

```bash
unset VOUCHFX_SAMPLES_CLI VOUCHFX_SAMPLES_CLI_VERSION
read -rsp 'Isolated database password: ' VOUCHFX_COMPOSE_PASSWORD; printf '\n'
export VOUCHFX_COMPOSE_PASSWORD
./scripts/run-sample.sh all
```

`all` enumerates all six sample directories, including `orders-dotnet-compose`, which the pinned source engine supports. Installed mode refuses `ledger-jsonrpc` because it requires its custom source runner, so installed `all` reports a nonzero result. See [candidate selection and custom-runner limits](#validate-an-installed-cli-candidate) below.

In default source mode, `scripts/run-sample.*` calls `scripts/bootstrap.*` automatically the first time (whenever `.vouchfx-src/` is missing), so a completely fresh clone only needs step 2. After advancing `ENGINE_PIN`, run bootstrap explicitly to replace an existing source checkout with the new pin.

## Validate an installed CLI candidate

The published CLI is available on NuGet.org. Install it and select
the independently recorded release version below. If the global tool is already installed,
use `dotnet tool update --global vouchfx --version 1.2.0` instead of the install command.

```bash
dotnet tool install --global vouchfx --version 1.2.0
export VOUCHFX_SAMPLES_CLI='vouchfx'
export VOUCHFX_SAMPLES_CLI_VERSION='1.2.0+0af21de5bd0a4e91ca002e03e6c256bc4e8ca4e8'
read -rsp 'Isolated database password: ' VOUCHFX_COMPOSE_PASSWORD; printf '\n'
export VOUCHFX_COMPOSE_PASSWORD
./scripts/run-sample.sh orders-dotnet-compose
```

```powershell
dotnet tool install --global vouchfx --version 1.2.0
$env:VOUCHFX_SAMPLES_CLI = 'vouchfx'
$env:VOUCHFX_SAMPLES_CLI_VERSION = '1.2.0+0af21de5bd0a4e91ca002e03e6c256bc4e8ca4e8'
$env:VOUCHFX_COMPOSE_PASSWORD = Read-Host -MaskInput 'Isolated database password'
.\scripts\run-sample.ps1 orders-dotnet-compose
```

Install the candidate using its release or candidate-artifact instructions. Select the executable and
the exact version declared in its manifest or release metadata; include any `+build` suffix. Replace
the example values below. Do not derive the expected version from the executable being checked.

```bash
export VOUCHFX_SAMPLES_CLI='/path/with spaces/vouchfx'
export VOUCHFX_SAMPLES_CLI_VERSION='VERSION_FROM_CANDIDATE_MANIFEST'
./scripts/run-sample.sh orders-dotnet
```

```powershell
$env:VOUCHFX_SAMPLES_CLI = 'C:\candidate tools\vouchfx.exe'
$env:VOUCHFX_SAMPLES_CLI_VERSION = 'VERSION_FROM_CANDIDATE_MANIFEST'
.\scripts\run-sample.ps1 orders-dotnet
```

`VOUCHFX_SAMPLES_CLI` may also be an executable command on `PATH`. Set both variables together.
Inspect its full version with `"$VOUCHFX_SAMPLES_CLI" --version` in Bash or
`& $env:VOUCHFX_SAMPLES_CLI --version` in PowerShell and compare it with the candidate metadata.
The runner checks `--version` before fixture setup, image builds or suite execution; a missing
executable, failed version command or mismatch exits nonzero. Installed mode neither bootstraps
nor restores the engine checkout, and does not use `ENGINE_PIN`. Standard suites retain
`--fail-on-env-error` and `--fail-on-inconclusive`; their failure reaches the runner's exit code.
Version matching identifies the declared candidate version; retain its artifact digest separately
when recording release evidence.

`ledger-jsonrpc` uses a custom host referencing the pinned source engine and Community provider.
Installed mode rejects custom-runner samples before setup/build rather than silently switching
engines. With `all`, standard samples continue, the refusal appears in the summary, and the final
exit remains nonzero. Run the custom-provider journey separately in source mode:

```bash
unset VOUCHFX_SAMPLES_CLI VOUCHFX_SAMPLES_CLI_VERSION
./scripts/run-sample.sh ledger-jsonrpc
```

```powershell
Remove-Item Env:VOUCHFX_SAMPLES_CLI, Env:VOUCHFX_SAMPLES_CLI_VERSION -ErrorAction SilentlyContinue
.\scripts\run-sample.ps1 ledger-jsonrpc
```

## User-supplied Docker Compose

[orders-dotnet-compose](../samples/orders-dotnet-compose/README.md) reuses the Orders
application and five assertions with an isolated Compose-owned database, Kafka broker
and application. The pinned source engine supports TCP service bindings and native
healthcheck readiness. Set `VOUCHFX_COMPOSE_PASSWORD` to a disposable credential,
bootstrap the pinned source, then run `./scripts/run-sample.sh orders-dotnet-compose`
or `./scripts/run-sample.ps1 orders-dotnet-compose`. Compose builds the shared app;
the standard runner does not build a duplicated `app/` for this variant.

For installed mode, select a Compose-capable candidate using the variables above.
The pinned-source CI matrix covers six samples, including this variant; the installed
CLI matrix also includes it among its five stock-CLI samples.
Source CLI/native Docker evidence and installed-package acceptance remain separate.
Keep Kafka's external loopback port 19092 free, and preserve both listener routes and `host-gateway` callback mapping.
The sample README documents readiness, digest pins and ownership-journal recovery.

### One-shot setup jobs

Declare setup work as a native Compose dependency of the long-running service you
export to Vouchfx. Set the setup service's restart policy to `"no"` and use
`service_completed_successfully`:

```yaml
services:
  setup:
    build: ./setup
    restart: "no"
  app:
    build: ./app
    depends_on:
      setup:
        condition: service_completed_successfully
```

Compose starts `app` only after `setup` exits successfully. A failed setup blocks
the dependent service and suite startup. Keep the setup service internal; export
the long-running service through the existing bindings. Vouchfx performs readiness
checks on exported endpoints; it does not independently check every exited Compose
service. See [Docker's startup-order guide](https://docs.docker.com/compose/how-tos/startup-order/).

## Reports

Reports land in `out/`:

- `out/<sample>-results.xml` — JUnit XML (for IDE/CI test-result integrations)
- `out/<sample>-report.html` — a self-contained HTML report, open it directly in a browser

The three ported migration suites (see [Migrating to vouchfx](migrating.md)) have their own runner, with the
same sequential discipline and report conventions (`out/migrations-<name>-*`):

```bash
./scripts/run-migrations.sh      # or .\scripts\run-migrations.ps1 on Windows
```

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

## Samples with custom runners

Most samples run via `scripts/run-sample.sh <name>`, which invokes the stock `vouchfx` engine CLI
with its 25 bundled Core providers. From Core 1.2.0 that CLI can also load trusted Community-tier
providers from the [vouchfx-providers](https://providers.vouchfx.io/) hub, installed with
`vouchfx providers install` or supplied with `--providers <dir>`; see the hub's
[consuming a provider guide](https://providers.vouchfx.io/docs/consuming-a-provider.html).
The sample runners configure none, but the CLI still loads whatever `VOUCHFX_PROVIDERS` and
`~/.vouchfx/providers` hold, and refuses to start (exit 3) if one of them cannot be loaded. Keep
both empty for runs that should match CI.

The **ledger-jsonrpc sample** has a `runner/` directory — a thin custom C# runner that:

1. References the Community `Vouchfx.Community.JsonRpc` package from NuGet
2. Constructs a provider registry that includes both Core and Community providers
3. Runs `.e2e.yaml` files against that registry

`scripts/run-sample.sh ledger-jsonrpc` (and the PowerShell twin) auto-detect the `runner/` directory and use it automatically — same reports, same exit codes as the stock-CLI path.

This is the **reference pattern** for bundling Community providers into one executable at build
time, and the only way to consume them before Core 1.2.0. From 1.2.0 the stock CLI can load the
same provider after `vouchfx providers install rpc.json-rpc`. Run the custom runner directly:

```bash
dotnet run --project samples/ledger-jsonrpc/runner -c Release -- \
  samples/ledger-jsonrpc/tests --html out/ledger-report.html --junit out/ledger-results.xml
```

The runner produces the same JUnit XML and HTML reports as the stock CLI, and the exit codes
remain identical (0 = Pass, 1 = Fail, 3 = EnvironmentError, 4 = Inconclusive). See
[`samples/ledger-jsonrpc/README.md`](../samples/ledger-jsonrpc/README.md) for details, or
[`docs/custom-runner.md`](custom-runner.md) for the detailed code recipe and design rationale.

## Restricted networks (egress proxy, blocked registries)

The default build assumes direct internet access. On a network that forces traffic through an inspecting proxy, or that cannot reach Docker Hub, three separate things break — each with its own fix. All of them are **opt-in**: with none of these set, every command behaves exactly as documented above.

### 1. Dependency images can't be pulled

Aspire/DCP pulls the managed dependency images (Postgres, Kafka, MySQL, Redis, RabbitMQ, NATS, Mailpit) itself at run time, so no script flag can redirect them. Point the Docker **daemon** at a registry mirror instead — this is transparent, needs no change to any suite, and keeps image references as `docker.io/...`:

```json
/* /etc/docker/daemon.json */
{ "registry-mirrors": ["https://mirror.gcr.io"] }
```

Restart the daemon afterwards. Verify with `docker info | grep -A1 "Registry Mirrors"`. Confirm your mirror serves the digests you expect before trusting a run — `docker pull postgres:17.6` should report the same `sha256:` digest as Docker Hub.

> Check this is permitted by your organisation's egress policy first. If Docker Hub is deliberately blocked, mirroring the same images may not be an approved route — allowlisting the registry is the cleaner fix.

### 2. `docker build` can't reach the network

`scripts/run-sample.sh` and `scripts/run-migrations.sh` read three optional variables:

| Variable | Effect |
|---|---|
| `VOUCHFX_SAMPLES_NO_BUILDKIT=1` | Build with the legacy builder. BuildKit resolves the `# syntax=docker/dockerfile:1` directive by first pulling that frontend image from Docker Hub, which fails before the build starts when Docker Hub is unreachable. |
| `VOUCHFX_SAMPLES_BUILD_NETWORK=host` | Passed through as `docker build --network host`. Required when the proxy is bound to the host's loopback address — a build container on the default bridge network has its own `127.0.0.1` and cannot see the host's. |
| `HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY` | Forwarded as build args when present. Docker predefines these, so no Dockerfile `ARG` is needed and the values stay out of `docker history`. |

```bash
export VOUCHFX_SAMPLES_NO_BUILDKIT=1
export VOUCHFX_SAMPLES_BUILD_NETWORK=host
export HTTPS_PROXY=http://127.0.0.1:3128
./scripts/run-sample.sh orders-dotnet
```

### 3. Maven rejects the proxy's TLS certificate

An inspecting proxy presents its own CA, and the `payments-java` build then fails every download with `PKIX path building failed`. Drop the proxy's CA as a PEM `*.crt` into [`samples/payments-java/app/certs/`](../samples/payments-java/app/certs/) — the build imports it and points Maven at the resulting truststore. That directory's `README.md` covers two traps worth knowing about, because both make a *seemingly successful* import do nothing:

- `keytool -importcert` reads only the **first** certificate from a multi-certificate PEM bundle and silently ignores the rest, so passing a full `ca-bundle.crt` trusts the wrong anchor while printing `Certificate was added to keystore`.
- Importing into the JDK's own `cacerts` is **not** sufficient on its own — `keytool -list` shows the alias, yet Maven still fails PKIX. The store has to be handed to the JVM explicitly via `-Djavax.net.ssl.trustStore`.

The other three samples need no CA handling: the .NET build reaches NuGet through the forwarded proxy, and the Python and Node builds fetch from PyPI and npm, which are typically direct.

## Why samples don't run concurrently on one machine

Inline suites bring up their topology through .NET Aspire's orchestrator (DCP); the Compose variant also reserves a fixed Kafka host port. Running two topologies at once on one host causes DCP port/network contention — the symptoms are usually a spurious `EnvironmentError` with a health-gate timeout that has nothing to do with either sample's actual code. `scripts/run-sample.* all` therefore always runs samples one after another, never in parallel, regardless of how many CPU cores are available.

## CI notes

`.github/workflows/samples-ci.yml` runs on code pushes and pull requests to `main`, plus manual dispatch; documentation-only changes are excluded. It uses a **matrix of separate runners** — one per sample — rather than running its selected samples on one machine:

- Each matrix job independently checks out the repo, sets up the pinned .NET SDK, bootstraps the pinned engine commit, and runs exactly one sample via `scripts/run-sample.sh <sample>`.
- Separate Windows and Linux jobs run Docker-free PowerShell and Bash sample-runner regressions. These check source/installed dispatch, version rejection and exit handling; live containers remain covered by the source-engine Linux matrix. Installed-mode subprocess stubs do not constitute live candidate acceptance.
- Because each sample gets its own runner, there's no DCP contention between samples in CI even though they execute at the same time — the sequential constraint above is about *one machine*, not about the samples being inherently unable to run in parallel.
- `fail-fast: false` — one sample's failure doesn't cancel the others; you get a result for every selected matrix sample.
- Each sample matrix job uploads its `out/` directory as an artifact (`reports-<sample>`) regardless of outcome (`if: always()`), so you can open the HTML report for a failed CI run without reproducing it locally first.
- The job timeout is generous (25 minutes) to comfortably cover image pulls, Aspire/DCP startup (roughly 20 seconds per managed resource), and the heavier samples' dependencies (e.g. SQL Server) — a run taking the full 25 minutes is itself worth investigating, but isn't expected in the normal case.

If a sample fails only in CI and not locally, the most common causes are: a cold image cache (first pull is slow — re-run), or a timeout tuned for a faster local machine than the CI runner (adjust the suite's `timeout`/`verifyMode: RETRY` backoff, not the CI job timeout).
