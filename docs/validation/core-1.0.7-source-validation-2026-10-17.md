# Core 1.0.7 source validation — 2026-10-17

Measured on Windows with Linux Docker containers against public Core source commit
`20d837a2f735c1c785db6593b58ebe10b3dd9f05`, tree
`0df0b96852f472ff0a80f5c3a88ded0f61215c81`. The pin helper resolved `v1.0.7`
to that commit and exited 0. A fresh `scripts/bootstrap.ps1` fetched the pinned
source and exited 0; its CLI build reported 0 warnings and 0 errors. The built
source CLI's `--version` exited 0 and returned
`1.0.0-0.local+20d837a2f735c1c785db6593b58ebe10b3dd9f05`.

This records source execution only. No official Core 1.0.7 CLI package was
downloaded, installed or accepted by this validation. The unchanged
[Core 1.0.6 acceptance record](core-1.0.6-acceptance.md) preserves its historical
source and installed-package results.

| Source case | Assertions passed | Other verdicts | Case runner exit |
|---|---:|---:|---:|
| `inventory-python` | 5 | 0 | 0 |
| `kafka-mtls` | 2 | 0 | 0 |
| `ledger-jsonrpc` | 10 | 0 | 0 |
| `orders-dotnet` | 5 | 0 | 0 |
| `orders-dotnet-compose` (targeted retry) | 5 | 0 | 0 |
| `payments-java` | 4 | 0 | 0 |
| Migration `from-postman` | 4 | 0 | 0 |
| Migration `from-xunit` | 3 | 0 | 0 |
| Migration `from-specflow` | 4 | 0 | 0 |

The six samples total 31 passing assertions, including the ledger custom
runner's 10; the three migrations separately total 11. Counts come from the CLI
scenario summaries. Each final case's JUnit report contains one scenario, with
zero failures, errors or skips. “Other verdicts” combines fail, environment-error
and inconclusive assertion counts for the final case execution.

The initial `scripts/run-sample.ps1 all` native exit was **3**: Compose was refused
before provisioning because its documented `VOUCHFX_COMPOSE_PASSWORD` input was
absent. Its initial summary was `pass=0 fail=0 envError=1 inconclusive=0`.
The other five case runners exited 0. The original log and all-run reports were
retained separately. Only Compose was retried, using a newly generated disposable
password supplied in the child process environment, then removed; its native exit
was 0 with five passing assertions. The initial aggregate exit remains 3; no
second full `all` run is claimed. `scripts/run-migrations.ps1` exited 0 and
reported exit 0 for each migration.

The standard source runner rebuilt `ledger-jsonrpc` against the new pin before
executing it; the runner build reported 0 warnings and 0 errors. Its
`packages.lock.json` required no tracked change. It remains custom-source-only.

## Measured Kafka security event and reports

The standard runner writes HTML and JUnit, without requesting a JSONL archive.
After the sequential sample and migration runs, this additional source CLI
invocation captured the real event alongside its two report projections:

```powershell
dotnet .vouchfx-src/src/Cli/Vouchfx.Cli/bin/Release/net8.0/vouchfx.dll `
  run samples/kafka-mtls/tests `
  --events out/kafka-mtls-security-results.jsonl `
  --junit out/kafka-mtls-security-results.xml `
  --html out/kafka-mtls-security-report.html `
  --fail-on-env-error --fail-on-inconclusive
```

Measured native exit: 0; assertions: 2 passed, 0 other verdicts; JUnit scenarios:
1. This repeat is separate event-projection coverage and is not added to the
31-assertion sample total.

The JSONL archive contains exactly one `security-confirmation` event (`v: 1`,
`schemaVersion: v1`), emitted at `2026-10-17T16:28:24.3156919+00:00`, with run ID
`cc9424eb8ae94e2eb27b63f4bdc47a3c`. Its observed fields are:

| Field | Value |
|---|---|
| `targetName` / `targetKind` | `broker` / `service` |
| `declaredProfile` / `declaredEndpoint` | `mtls` / `9092` |
| `observedAddress` / `observedProtocol` | `localhost:19093` / `Tls13` |
| `clientIdentityResolved` | `true` |
| `level` | `AuthenticatedRoundTrip` |
| `replayed` | `false` |

The decoded JUnit property `vouchfx.securityConfirmation.0` exactly equals that
JSON event, including timestamp and run ID. The HTML “Security confirmations”
table contains one matching row with the same target, declaration, address,
protocol, identity-resolution flag, level and run ID, labelled “Build-time probe”.
Its qualification that identity resolution alone does not establish peer
acceptance is present. These checks exited 0.

The actual probe diagnostic separately records that the broker answered a Kafka
`ApiVersions` request using the client identity and refused the same request on a
second connection without a client certificate. That probe evidence establishes
this run's mTLS confirmation; the two successful publish/consume assertions alone
would not establish client-authentication enforcement. Topic-level authorisation
was not confirmed.

SHA-256 of the retained event-run artifacts:

| Artifact under `out/` | SHA-256 |
|---|---|
| `kafka-mtls-security-results.jsonl` | `c6c5889ec19f5549251e230a4cc3af3507266a65a0e4484e36ff2b830be2c594` |
| `kafka-mtls-security-results.xml` | `690ed659acb19ed3c70e599f39681768a82e5a53a29e4c9b67186f924e35d018` |
| `kafka-mtls-security-report.html` | `761a0c6c4fe163def1162204d2c91f9e6bc4fb6b92c0466780bb0be62be2b99c` |

Per-command logs, native exit markers, the original all-run artifact snapshot and
the verification receipt are retained outside the repository. Generated reports
remain ignored under `out/`; no test certificates or credentials are committed.
