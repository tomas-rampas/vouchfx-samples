# Orders with a user-supplied Docker Compose environment

This variant reuses the [orders-dotnet application](../orders-dotnet/app) and its
five assertions: place an order, query its PostgreSQL row, observe its Kafka event,
receive the outbound callback and retrieve the order. The suite keeps the UUID
parameter cast and container-reachable callback placeholder used by the inline example.

`compose.yaml` owns the application, database, broker, network and database volume.
`environment.compose.yaml` maps those native resources to logical test targets.
The suite selects the adapter through `environment.source`; ordinary HTTP, PostgreSQL,
Kafka and webhook providers perform the assertions. No custom provider is required.

## Run with a Compose-capable CLI

Use Docker with Linux containers and an explicitly selected CLI candidate supporting
TCP service bindings, native healthcheck readiness and Kafka retained-log partition
assignment. The Kafka assertion must read all actual partitions from earliest offsets
without waiting for a fresh consumer group rebalance; its one-second attempt budget
remains unchanged. The current `ENGINE_PIN`
and published `1.0.0-rc.6` default do not support this variant. Follow the candidate's
build/install instructions and retain its version and artifact digest; a source run
does not prove installed-package compatibility.

From the repository root, validate and run the exact built source CLI DLL:

```powershell
$cli = 'C:\path\to\vouchfx.dll'
dotnet $cli validate samples/orders-dotnet-compose/tests/orders.e2e.yaml
$env:VOUCHFX_COMPOSE_PASSWORD = Read-Host -MaskInput 'Isolated database password'
dotnet $cli run samples/orders-dotnet-compose/tests/orders.e2e.yaml `
  --fail-on-env-error --fail-on-inconclusive `
  --junit orders-compose.xml --events orders-compose.jsonl
```

Validation binds authoring inputs; credentials are resolved at acquisition. Select
a matching candidate executable with `VOUCHFX_SAMPLES_CLI` and its externally supplied
`VOUCHFX_SAMPLES_CLI_VERSION` to use the [standard runner](../../docs/RUNNING.md#validate-an-installed-cli-candidate):

```bash
read -rsp 'Isolated database password: ' VOUCHFX_COMPOSE_PASSWORD; printf '\n'
export VOUCHFX_COMPOSE_PASSWORD
./scripts/run-sample.sh orders-dotnet-compose
```

The PowerShell equivalent is `./scripts/run-sample.ps1 orders-dotnet-compose`.
The variant has no duplicated `app/`; Compose builds the shared application itself.
Require all five assertions to execute and pass. HTTP 201 alone does not prove Kafka
delivery: the application catches broker delivery failures before returning its response.

## Networking and readiness

The app connects to `postgres:5432` and `broker:29092` on Compose DNS. Host-side
PostgreSQL and HTTP assertions use discovered dynamic IPv4 loopback mappings.
Kafka's separate external listener advertises `127.0.0.1:19092`; this port must be free.
Change both its published port and advertised listener together if your isolated
test host needs another port. Remote Docker contexts and IPv6-only mappings are unsupported.

Kafka readiness runs `cub kafka-ready` against the internal listener and the adapter
requires the enabled native healthcheck to become healthy. TCP reachability alone
does not establish broker readiness. PostgreSQL uses `pg_isready`; app readiness
checks `GET /` after table initialisation. The app has a `host-gateway` mapping for
`host.docker.internal`, used by `{cb_container}` to reach the engine's webhook listener.
Docker Desktop source execution and native Linux-host callback routing are separate
validation environments; success in one does not establish the other.

## Isolation and cleanup

Database passwords remain runtime `${secret:env/VOUCHFX_COMPOSE_PASSWORD}` references.
Use a fresh credential for these disposable resources. Do not add fixed container names,
external volumes/networks or borrowed resources. Each acquisition uses an isolated
project; teardown removes its containers, networks and database volume. Built application
images and Docker build cache are separate image-store effects.

If cleanup cannot finish, retain the ownership journal path from the diagnostic and
use `vouchfx environment cleanup --journal <path>` with the same selected CLI and daemon.
Never use `docker system prune` as sample cleanup. Startup and cleanup budgets are
180 and 30 seconds. Cancellation through `--shutdown-on-stdin-eof` requires a live
controlled input pipe; it is distinct from OS Ctrl-C/SIGTERM coverage.

Upstream PostgreSQL, Kafka and .NET image references are pinned by digest. The
Confluent 7.6.1 image is a reproducible compatibility baseline, not a claim of current
security support. Image pinning does not replace routine dependency/image maintenance.
