# Samples acceptance — 25 October 2026

Measured locally on Windows with .NET SDK 8.0.426 and Docker 29.6.1 using Linux containers.
The tested samples checkout was
[`0fc7426bb28be793192593c7ccb7179442210f12`](https://github.com/tomas-rampas/vouchfx-samples/commit/0fc7426bb28be793192593c7ccb7179442210f12).
These results identify that checkout, not a later documentation revision or a hosted CI run.

## Source and installed results

| Case | Pinned-source assertions / exit | Installed Core 1.2.1 assertions / exit |
|---|---:|---:|
| `inventory-python` | 5 / 0 | 5 / 0 |
| `kafka-mtls` | 2 / 0 | 2 / 0 |
| `ledger-jsonrpc` | 10 / 0 | Not supported by the installed-mode runner |
| `orders-dotnet` | 5 / 0 | 5 / 0 |
| `orders-dotnet-compose` | 5 / 0 | 5 / 0 |
| `payments-java` | 4 / 0 | 4 / 0 |
| Migration `from-postman` | 4 / 0 | Not run |
| Migration `from-xunit` | 3 / 0 | Not run |
| Migration `from-specflow` | 4 / 0 | Not run |

All 14 case executions exited 0. CLI summaries reported 63 passing business assertions:
31 source-sample assertions, 11 migration assertions and 21 installed-package assertions.
There were zero fail, environment-error or inconclusive verdicts. The 14 fresh JUnit reports
contain one scenario each, with zero failures, errors or skips; business assertions are not
separate JUnit test cases. HTML and JUnit reports were retained for each execution.

Both Kafka runs confirmed mutual TLS at `AuthenticatedRoundTrip`: the declared client certificate
was accepted and a connection without it was rejected. That probe does not establish topic
authorisation. No sample source changes were required, and no running test containers remained.

## Engine identities

Source bootstrap exited 0 with zero warnings and errors at the unchanged `ENGINE_PIN`,
[`0af21de5bd0a4e91ca002e03e6c256bc4e8ca4e8`](https://github.com/tomas-rampas/vouchfx/commit/0af21de5bd0a4e91ca002e03e6c256bc4e8ca4e8).
Its CLI reported `1.0.0-0.local+0af21de5bd0a4e91ca002e03e6c256bc4e8ca4e8`.
`ledger-jsonrpc` used its custom source runner, including the Community JSON-RPC provider.

Installed runs used the official
[`vouchfx.1.2.1.nupkg` GitHub Release asset](https://github.com/tomas-rampas/vouchfx/releases/download/v1.2.1/vouchfx.1.2.1.nupkg).
Its SHA-256 was `a4c315d1d48ce43d976ad80f1f2a2309dc0109d4fdd513402ea3fc6bf61e929b`.
The isolated installed CLI reported `1.2.1+204267fdfef8eb139a4cd88e08ea917e97bf7668`, checked by
the sample runner before each execution. NuGet did not initially list the version, so this run
used a local feed containing the official release package. It does not prove NuGet installation.

## Commands

Each sample ran separately and sequentially through `scripts/run-sample.ps1 <sample-name>`.
The migrations ran through `scripts/run-migrations.ps1`, after source bootstrap:

```powershell
pwsh -NoProfile -File scripts/bootstrap.ps1
pwsh -NoProfile -File scripts/run-sample.ps1 orders-dotnet-compose
pwsh -NoProfile -File scripts/run-migrations.ps1
```

For the five installed-mode samples, the official package was downloaded into a disposable
`feed` directory and installed into a separate `cli` directory:

```powershell
gh release download v1.2.1 --repo tomas-rampas/vouchfx `
  --pattern vouchfx.1.2.1.nupkg --dir ./feed
dotnet tool install vouchfx --version 1.2.1 --tool-path ./cli --add-source ./feed
$env:VOUCHFX_SAMPLES_CLI = (Resolve-Path ./cli/vouchfx.exe).Path
$env:VOUCHFX_SAMPLES_CLI_VERSION = '1.2.1+204267fdfef8eb139a4cd88e08ea917e97bf7668'
```

The Compose runs used a fresh disposable `VOUCHFX_COMPOSE_PASSWORD`, kept out of logs.
The checked-in Compose file built the shared application's default Dockerfile. A custom
`build.dockerfile` filename is supported by native Compose but was not a separate case in this run.
See [running the samples](../RUNNING.md) for the full prerequisites and selection commands.
