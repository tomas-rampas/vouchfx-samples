# Core 1.0.7 installed CLI acceptance — 2026-10-17

Measured on Windows with Linux Docker containers using the official `vouchfx`
CLI package `1.0.7`. The CLI reported
`1.0.7+20d837a2f735c1c785db6593b58ebe10b3dd9f05`. The package corresponds to
public Core source commit
[`20d837a2f735c1c785db6593b58ebe10b3dd9f05`](https://github.com/tomas-rampas/vouchfx/commit/20d837a2f735c1c785db6593b58ebe10b3dd9f05),
tree `0df0b96852f472ff0a80f5c3a88ded0f61215c81`. The installed CLI payload
matched the official package. Runs used the installed-candidate path and its
exact-version guard; `ENGINE_PIN` was not used.

| Stock CLI sample | Business assertions passed | Other verdicts | Native runner exit |
|---|---:|---:|---:|
| `inventory-python` | 5 | 0 | 0 |
| `kafka-mtls` | 2 | 0 | 0 |
| `orders-dotnet` | 5 | 0 | 0 |
| `orders-dotnet-compose` | 5 | 0 | 0 |
| `payments-java` | 4 | 0 | 0 |

The five CLI summaries total 21 passing business assertions, with zero fail,
environment-error or inconclusive verdicts. Each native PowerShell sample
runner exited 0. Each case's JUnit report contains one scenario with zero
failures, errors or skips; the assertion counts above come from the CLI
summaries, not from the JUnit scenario count.

The runs used the repository's installed-candidate version guard. For example,
after installing the official tool, select its full declared version and run a
stock sample:

```powershell
dotnet tool install --global vouchfx --version 1.0.7
$env:VOUCHFX_SAMPLES_CLI = 'vouchfx'
$env:VOUCHFX_SAMPLES_CLI_VERSION = '1.0.7+20d837a2f735c1c785db6593b58ebe10b3dd9f05'
.\scripts\run-sample.ps1 inventory-python
```

Separately, a direct CLI event-projection run for `kafka-mtls` exited 0 and
passed its two assertions. It produced JSONL, JUnit and HTML reports; the JSONL
archive contained nine events, including one `security-confirmation` event.
This repeat is separate from, and not added to, the 21-assertion stock-sample
total.

`ledger-jsonrpc` is not included: it uses its custom source runner and is not a
stock-CLI case. The [Core 1.0.7 source validation record](core-1.0.7-source-validation-2026-10-17.md)
documents source-mode runs, while the [Core 1.0.6 acceptance record](core-1.0.6-acceptance.md)
preserves historical source and installed-package evidence.
