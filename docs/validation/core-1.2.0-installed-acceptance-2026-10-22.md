# Core 1.2.0 installed CLI acceptance — 2026-10-22

Measured on GitHub-hosted Ubuntu runners with Linux Docker containers, in
[Samples CI run 39756483762](https://github.com/tomas-rampas/vouchfx-samples/actions/runs/39756483762)
(attempt 1), using the official `vouchfx` CLI package `1.2.0` installed from NuGet.org into a
job-local tool path. Before starting a sample, each job's runner read the installed CLI's
reported version, `1.2.0+0af21de5bd0a4e91ca002e03e6c256bc4e8ca4e8`, and required it to equal the
expected `VOUCHFX_SAMPLES_CLI_VERSION`. `ENGINE_PIN` was not used. The package corresponds to
public Core source commit
[`0af21de5bd0a4e91ca002e03e6c256bc4e8ca4e8`](https://github.com/tomas-rampas/vouchfx/commit/0af21de5bd0a4e91ca002e03e6c256bc4e8ca4e8),
tree `c0e6f8635283c901601c2e41849b55fe152cafc5`. Earlier records were measured on Windows.

| Stock CLI sample | Business assertions passed | Other verdicts | Native runner exit |
|---|---:|---:|---:|
| `inventory-python` | 5 | 0 | 0 |
| `kafka-mtls` | 2 | 0 | 0 |
| `orders-dotnet` | 5 | 0 | 0 |
| `orders-dotnet-compose` | 5 | 0 | 0 |
| `payments-java` | 4 | 0 | 0 |

The five CLI summaries total 21 passing business assertions, with zero fail,
environment-error or inconclusive verdicts, and each Bash sample runner exited 0. The
assertion counts come from the CLI summaries. Each job uploaded its JUnit and HTML reports as
an artefact; their contents are not recorded here. The installed `kafka-mtls` run confirmed
the broker's mutual TLS at level `AuthenticatedRoundTrip`, as the source run did.

The runs used the repository's installed-candidate version guard, as CI does:

```bash
dotnet tool install vouchfx --version 1.2.0 --tool-path "$HOME/official-cli" \
  --add-source https://api.nuget.org/v3/index.json
export VOUCHFX_SAMPLES_CLI="$HOME/official-cli/vouchfx"
export VOUCHFX_SAMPLES_CLI_VERSION='1.2.0+0af21de5bd0a4e91ca002e03e6c256bc4e8ca4e8'
./scripts/run-sample.sh inventory-python
```

`ledger-jsonrpc` is not included: it uses its custom source runner, and the sample runner
refuses installed mode for a sample with one. From Core 1.2.0 the stock CLI can load that
sample's Community provider after `vouchfx providers install rpc.json-rpc`, but no end-to-end
run of the sample through the stock CLI is recorded here. The
[Core 1.2.0 source validation record](core-1.2.0-source-validation-2026-10-22.md) documents the
source-mode runs of the same CI run.
