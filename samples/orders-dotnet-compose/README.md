# Orders with a user-supplied Docker Compose environment

This variant reuses the [orders-dotnet application](../orders-dotnet/app) and its
five assertions: place an order, query its PostgreSQL row, observe its Kafka event,
receive the outbound callback and retrieve the order. The suite keeps the UUID
parameter cast and container-reachable callback placeholder used by the inline example.

`compose.yaml` owns the application, database, broker, network and database volume.
`environment.compose.yaml` maps those native resources to logical test targets.
The suite selects the adapter through `environment.source`; ordinary HTTP, PostgreSQL,
Kafka and webhook providers perform the assertions. No custom provider is required.

## Run with pinned source or an installed candidate

Use Docker with Linux containers. The engine source in `ENGINE_PIN` supports TCP
service bindings, native healthcheck readiness and Kafka retained-log partition
assignment for this variant. The pinned source is public in
[Core source commit](https://github.com/tomas-rampas/vouchfx/commit/0af21de5bd0a4e91ca002e03e6c256bc4e8ca4e8). Source bootstrap is independent
of stable CLI and SDK package publication. The Kafka assertion reads all actual partitions from earliest
offsets without waiting for a fresh consumer group rebalance; its one-second attempt
budget remains unchanged. For installed mode, use the public CLI selected by the commands in
[installed CLI selection](../../docs/RUNNING.md#validate-an-installed-cli-candidate). Retain its version and artifact digest;
a source run does not prove installed-package compatibility.

From the repository root, bootstrap the pinned source, then validate and run its
exact built CLI DLL (replace the path below):

```powershell
.\scripts\bootstrap.ps1
$cli = 'C:\path\to\vouchfx.dll'
dotnet $cli validate samples/orders-dotnet-compose/tests/orders.e2e.yaml
$env:VOUCHFX_COMPOSE_PASSWORD = Read-Host -MaskInput 'Isolated database password'
dotnet $cli run samples/orders-dotnet-compose/tests/orders.e2e.yaml `
  --fail-on-env-error --fail-on-inconclusive `
  --junit orders-compose.xml --events orders-compose.jsonl
```

Validation binds authoring inputs; credentials are resolved at acquisition. After
bootstrap, the standard runner uses the pinned source by default:

```bash
unset VOUCHFX_SAMPLES_CLI VOUCHFX_SAMPLES_CLI_VERSION
read -rsp 'Isolated database password: ' VOUCHFX_COMPOSE_PASSWORD; printf '\n'
export VOUCHFX_COMPOSE_PASSWORD
./scripts/run-sample.sh orders-dotnet-compose
```

The PowerShell equivalent is `./scripts/run-sample.ps1 orders-dotnet-compose`. To
validate an installed candidate instead, set `VOUCHFX_SAMPLES_CLI` and its externally
supplied `VOUCHFX_SAMPLES_CLI_VERSION`; see [installed candidate validation](../../docs/RUNNING.md#validate-an-installed-cli-candidate).
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
