# Core 1.2.0 source validation — 2026-10-22

Measured on GitHub-hosted Ubuntu runners with Linux Docker containers, in
[Samples CI run 39756483762](https://github.com/tomas-rampas/vouchfx-samples/actions/runs/39756483762)
(attempt 1) for the Core 1.2.0 adoption pull request. Every job checked out the pull request's
merge commit `9e722485e38c4e93c6346c78cd38395570f6844e`, which merges head
`585cd0fd6d3ea1358ec116992670a0ee70c05099` into `be79b96af5be338a9b6f705de4423093d0553114`.
Earlier records were measured on Windows; this one comes from the hosted Linux jobs.

The pin helper resolved `v1.2.0` to public Core source commit
[`0af21de5bd0a4e91ca002e03e6c256bc4e8ca4e8`](https://github.com/tomas-rampas/vouchfx/commit/0af21de5bd0a4e91ca002e03e6c256bc4e8ca4e8),
tree `c0e6f8635283c901601c2e41849b55fe152cafc5`, and exited 0. In each source job a fresh
`scripts/bootstrap.sh` fetched that commit, built the engine CLI with 0 warnings and 0 errors
under .NET SDK 8.0.426, and reported the build as coming from that commit. The jobs did not
print the built source CLI's `--version`.

This records source execution only. The
[Core 1.2.0 installed acceptance record](core-1.2.0-installed-acceptance-2026-10-22.md)
covers the official CLI package separately.

| Source case | Assertions passed | Other verdicts | Case runner exit |
|---|---:|---:|---:|
| `inventory-python` | 5 | 0 | 0 |
| `kafka-mtls` | 2 | 0 | 0 |
| `ledger-jsonrpc` | 10 | 0 | 0 |
| `orders-dotnet` | 5 | 0 | 0 |
| `orders-dotnet-compose` | 5 | 0 | 0 |
| `payments-java` | 4 | 0 | 0 |
| Migration `from-postman` | 4 | 0 | 0 |
| Migration `from-xunit` | 3 | 0 | 0 |
| Migration `from-specflow` | 4 | 0 | 0 |

The six samples total 31 passing assertions, including the ledger custom runner's 10; the
three migrations separately total 11. Counts come from the CLI scenario summaries, and each
case ran in its own job. “Other verdicts” combines fail, environment-error and inconclusive
assertion counts. The stock sample runner passes `--fail-on-env-error` and
`--fail-on-inconclusive`, so a 0 exit also rules out those verdicts. No polled step needed a
second attempt. Each job uploaded its JUnit and HTML reports as an artefact; the logs record
the files but not their contents, so no JUnit count is claimed here.

The standard source runner rebuilt the `ledger-jsonrpc` custom runner against the new pin
before executing it, with 0 warnings and 0 errors. Its `packages.lock.json` is recorded but
not enforced, because the runner does not restore in locked mode, and the job has no diff
step, so this run does not show whether restore would have changed it. This adoption commits
no lock file change.

The `kafka-mtls` run confirmed the broker's declared mutual TLS at level
`AuthenticatedRoundTrip`: TLS 1.3 at the host-published endpoint with the client identity
resolved, and the same request refused on a second connection that presented no client
certificate. The job generated its disposable test certificates during the run.

Health-check noise before each scenario started and connection warnings after each verdict
appeared in the logs, as in earlier runs; none changed a verdict or an exit code. The
complete logs remain in the GitHub Actions run, and nothing sensitive is committed.
