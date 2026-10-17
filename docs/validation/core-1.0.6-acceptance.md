# Core 1.0.6 acceptance

Measured 2026-10-17 against public Core 1.0.6 source commit `9d3371857c408022dcdb5ab2f233cfb8aa46f75b`. The installed candidate was the official NuGet CLI `1.0.6+9d3371857c408022dcdb5ab2f233cfb8aa46f75b`, package SHA-256 `395515e9699ca7bf3dc75fd44a93dabf0352cc53db2bc42975865faa35ec9776`.

| Validation path | Case | CLI assertions passed | Other verdicts | Runner exit |
|---|---|---:|---:|---:|
| Official installed CLI | `inventory-python` | 5 | 0 | 0 |
| Official installed CLI | `kafka-mtls` | 2 | 0 | 0 |
| Official installed CLI | `orders-dotnet` | 5 | 0 | 0 |
| Official installed CLI | `orders-dotnet-compose` | 5 | 0 | 0 |
| Official installed CLI | `payments-java` | 4 | 0 | 0 |
| Pinned source mode | `inventory-python` | 5 | 0 | 0 |
| Pinned source mode | `kafka-mtls` | 2 | 0 | 0 |
| Pinned source mode | `ledger-jsonrpc` | 10 | 0 | 0 |
| Pinned source mode | `orders-dotnet` | 5 | 0 | 0 |
| Pinned source mode | `orders-dotnet-compose` | 5 | 0 | 0 |
| Pinned source mode | `payments-java` | 4 | 0 | 0 |
| Pinned source mode | Migration `from-postman` | 4 | 0 | 0 |
| Pinned source mode | Migration `from-xunit` | 3 | 0 | 0 |
| Pinned source mode | Migration `from-specflow` | 4 | 0 | 0 |

The installed stock CLI total was 21 passing assertions across five cases. Source mode totaled 31 passing assertions across six samples; the three migration suites totaled 11. For every row, “other verdicts” is the combined fail, environment-error, and inconclusive count. Each source sample runner exited 0; the migration runner and each reported suite also exited 0.

The installed-candidate runs used the PowerShell `scripts/run-sample.ps1` runner on Windows with Linux Docker containers. The five installed cases left zero containers and preserved the same three Docker network IDs observed before the run. The JUnit report for each case contains one scenario with zero failures, errors, or skips; the assertion counts above come from each CLI summary, not the JUnit scenario count.

The first collector incorrectly compared the one JUnit scenario with the CLI assertion count and marked its receipt as failed before starting the next sample. The original collector output and case artifacts were retained. A corrected collector read the existing results, emitted a final receipt with exit code 0, and no sample was rerun. The final receipt records five native runner exits of 0 and zero fail, environment-error, or inconclusive verdicts. The package was selected from its declared release metadata and its artifact digest was recorded separately; version selection and the candidate validation procedure are documented in [Validate an installed CLI candidate](../RUNNING.md#validate-an-installed-cli-candidate).

`ledger-jsonrpc` remains custom-source-only because its runner references the pinned source engine. It is included in the source-mode count and not in the installed stock-CLI count.

For an installed Core 1.0.6 candidate, the repository scripts accept the executable and exact declared version together. After installing the NuGet tool, for example:

```powershell
dotnet tool install --global vouchfx --version 1.0.6
$env:VOUCHFX_SAMPLES_CLI = 'vouchfx'
$env:VOUCHFX_SAMPLES_CLI_VERSION = '1.0.6+9d3371857c408022dcdb5ab2f233cfb8aa46f75b'
.\scripts\run-sample.ps1 inventory-python
```

The runner checks `--version` against `VOUCHFX_SAMPLES_CLI_VERSION` before starting setup or the suite. Use the version declared by the candidate metadata, including its `+build` suffix; do not infer the expected value from the executable under test. See [the full candidate instructions](../RUNNING.md#validate-an-installed-cli-candidate).
