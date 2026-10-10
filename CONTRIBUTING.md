# Contributing to vouchfx-samples

This repository hosts reference samples that show the [vouchfx](https://github.com/tomas-rampas/vouchfx) engine testing a real, running system end-to-end — one business transaction crossing a REST call, a database mutation, a queue event, an outbound webhook. It does **not** host the engine itself, its providers, or the YAML DSL — see [Engine changes belong upstream](#engine-changes-belong-upstream) below.

## What belongs here

Each sample lives under `samples/<name>/` and contains:

1. **`app/` (optional)** — a real application with a `Dockerfile` that builds a runnable image via `docker build samples/<name>/app`. Omit it for infrastructure-only samples such as `kafka-mtls`; the runner then skips the image build.
2. **`tests/*.e2e.yaml`** — one or more `.e2e.yaml` suites exercising that flow through the vouchfx engine, per the [YAML DSL specification](https://github.com/tomas-rampas/vouchfx/blob/main/docs/02_YAML_DSL_Specification_and_VSCode_Extension_Design.md).
3. **`README.md`** — what the sample demonstrates, the technology pairing, how to run it standalone, and what a passing run looks like.

Optional `setup.sh` / `setup.ps1` scripts generate certificates or other fixtures before any build or suite run. Provide both when setup is required, and return a nonzero exit code on failure. A `runner/` project may integrate a custom provider.

A new sample is welcome when it demonstrates a **distinct** technology pairing or integration pattern not already covered by the existing samples (`orders-dotnet`, `inventory-python`, `payments-java`, `ledger-jsonrpc`, `kafka-mtls`). Open a [sample request issue](../../issues/new?template=sample-request.yml) first if you'd like early feedback on fit before doing the work.

## Quality bar

Before opening a PR, confirm:

- **The suite passes via the standard entry point:** `scripts/run-sample.sh <your-sample>` (or `scripts/run-sample.ps1` on Windows) exits `0`. This is exactly what CI runs (`.github/workflows/samples-ci.yml`) — if it does not pass locally, it will not pass in CI.
- **When `app/` exists, its Dockerfile builds cleanly:** `docker build -t vouchfx-samples-<name>:local samples/<name>/app`.
- **The sample is self-contained.** A fresh clone, `scripts/bootstrap.*`, then `scripts/run-sample.* <name>` must be sufficient — no dependency on state outside what the suite's `environment.dependencies` / `environment.seed` describe.
- **No secrets, credentials, or personal data.** Samples run in CI on every push to `main` and on every pull request.
- **The README has at least: what it demonstrates, the technology pairing, how to run it, and what success looks like** (see `docs/RUNNING.md` for the verdict taxonomy to describe this accurately).

## Developer Certificate of Origin (DCO)

All commits must carry a `Signed-off-by:` trailer, confirming you have the right to contribute the change under this repository's licence:

```bash
git commit -s -m "Add inventory-python restock sample"
```

Already committed without it? Add the trailer retroactively:

```bash
git commit --amend --signoff          # most recent commit
git rebase --signoff HEAD~N           # last N commits
```

See [developercertificate.org](https://developercertificate.org/) for what you are attesting to.

## Runner regression tests

For sample-runner changes, run the Docker-free native subprocess regressions for both shells:

```powershell
pwsh -NoProfile -File scripts/tests/test-run-sample.ps1
```

```bash
bash scripts/tests/test-run-sample.sh
```

These checks cover setup ordering, optional image builds, installed-candidate version checks,
custom-runner refusal, failure propagation and `all` aggregation. Both harnesses also run in
Samples CI. Neither substitutes for live source or installed-candidate acceptance.

## Engine changes belong upstream

Default source mode consumes the engine at `ENGINE_PIN`; explicit installed mode consumes the
executable/version selected by `VOUCHFX_SAMPLES_CLI` and `VOUCHFX_SAMPLES_CLI_VERSION`. See
[installed candidate validation](docs/RUNNING.md#validate-an-installed-cli-candidate). Custom
provider runners remain source-based. This repository does not modify the engine. If you find an
engine bug, want a new provider, or want to change the DSL, take it to the engine repository:

- Engine [`CONTRIBUTING.md`](https://github.com/tomas-rampas/vouchfx/blob/main/CONTRIBUTING.md)
- Engine issues: <https://github.com/tomas-rampas/vouchfx/issues>
- Provider listings and Vouched badge requests: [vouchfx-providers](https://github.com/tomas-rampas/vouchfx-providers)

## Licence

By contributing, you agree your contribution is licensed under this repository's [LICENSE](LICENSE).

---

Thank you for contributing to vouchfx-samples — real, working samples are what make the engine's promise (topological parity across local/SaaS/CI) tangible to a first-time reader.

## Volatile facts on the documentation site

Version numbers and registry counts shown on the rendered site are resolved at build time via `{{fact:...}}` tokens in `scripts/build_site.py` (with a checked-in fallback in `site/facts-fallback.json`). When writing documentation prose, do not hard-code the current engine or package version — reference the mechanism (a pin file, "the current release") or use a fact token, so pages cannot silently rot. Sibling repos trigger a rebuild here through the `repository_dispatch` trigger in `.github/workflows/pages.yml` (the workflow's `notify` job is the outbound half — it tells the siblings when this repo's own docs change).
