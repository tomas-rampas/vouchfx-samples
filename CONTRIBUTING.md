# Contributing to vouchfx-samples

This repository hosts reference samples that show the [vouchfx](https://github.com/tomas-rampas/vouchfx) engine testing a real, running system end-to-end — one business transaction crossing a REST call, a database mutation, a queue event, an outbound webhook. It does **not** host the engine itself, its providers, or the YAML DSL — see [Engine changes belong upstream](#engine-changes-belong-upstream) below.

## What belongs here

Each sample lives under `samples/<name>/` and has exactly three parts:

1. **`app/`** — a real application with a `Dockerfile` that builds a runnable image via `docker build samples/<name>/app`. It should exercise a genuine cross-boundary flow — the whole reason vouchfx exists — not a single in-process function.
2. **`tests/*.e2e.yaml`** — one or more `.e2e.yaml` suites exercising that flow through the vouchfx engine, per the [YAML DSL specification](https://github.com/tomas-rampas/vouchfx/blob/main/docs/02_YAML_DSL_Specification_and_VSCode_Extension_Design.md).
3. **`README.md`** — what the sample demonstrates, the technology pairing, how to run it standalone, and what a passing run looks like.

A new sample is welcome when it demonstrates a **distinct** technology pairing or integration pattern not already covered by the existing samples (`orders-dotnet`, `inventory-python`, `payments-java`). Open a [sample request issue](../../issues/new?template=sample-request.yml) first if you'd like early feedback on fit before doing the work.

## Quality bar

Before opening a PR, confirm:

- **The suite passes via the standard entry point:** `scripts/run-sample.sh <your-sample>` (or `scripts/run-sample.ps1` on Windows) exits `0`. This is exactly what CI runs (`.github/workflows/samples-ci.yml`) — if it does not pass locally, it will not pass in CI.
- **The Dockerfile builds cleanly** with no manual pre-steps: `docker build -t vouchfx-samples-<name>:local samples/<name>/app`.
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

## Engine changes belong upstream

This repository consumes the vouchfx engine at a pinned commit (`ENGINE_PIN`) — it builds against it, it does not modify it. If you find an engine bug, want a new provider, or want to change the DSL, take it to the engine repository instead:

- Engine [`CONTRIBUTING.md`](https://github.com/tomas-rampas/vouchfx/blob/main/CONTRIBUTING.md)
- Engine issues: <https://github.com/tomas-rampas/vouchfx/issues>
- Provider listings and Vouched badge requests: [vouchfx-providers](https://github.com/tomas-rampas/vouchfx-providers)

## Licence

By contributing, you agree your contribution is licensed under this repository's [LICENSE](LICENSE).

---

Thank you for contributing to vouchfx-samples — real, working samples are what make the engine's promise (topological parity across local/SaaS/CI) tangible to a first-time reader.

## Volatile facts on the documentation site

Version numbers and registry counts shown on the rendered site are resolved at build time via `{{fact:...}}` tokens in `scripts/build_site.py` (with a checked-in fallback in `site/facts-fallback.json`). When writing documentation prose, do not hard-code the current engine or package version — reference the mechanism (a pin file, "the current release") or use a fact token, so pages cannot silently rot. Sibling repos rebuild this site automatically when their docs change (see the `notify` job in `.github/workflows/pages.yml`).
