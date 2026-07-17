# Security Policy

This repository contains **sample applications and `.e2e.yaml` suites** for
[vouchfx](https://github.com/tomas-rampas/vouchfx). Its purpose is to demonstrate
the engine testing real polyglot systems end-to-end — not to provide
production-ready service code. That shapes what is, and is not, a security issue
here.

## The samples are deliberately demo-grade

The sample services are **not production templates**. Do not copy them into a
production system and expect a hardened baseline. In particular, the following are
known, deliberate properties of the demos, not reportable vulnerabilities:

- **No authentication on the sample APIs.** The services (orders-dotnet,
  inventory-python, payments-java, ledger-jsonrpc) expose unauthenticated
  endpoints because they run inside a vouchfx-orchestrated, throwaway container
  topology on a local Docker network.
- **A documented SSRF-style callback surface in orders-dotnet.** The order flow
  deliberately POSTs an outbound webhook to a caller-influenced callback URL so
  that the suite can exercise `webhook-listen.http`. In a production service this
  shape would require strict allow-listing; here it exists precisely to be tested.
- Demo-grade configuration generally: throwaway plain-text credentials in the
  standalone `docker run` instructions in the sample READMEs, no TLS between the
  demo services and their containerised databases and brokers, and similar
  conveniences appropriate to disposable test topologies.

Reports that a sample "lacks auth" or "allows SSRF" as designed above will be
closed as intended behaviour. If, however, a sample's demo-grade surface can be
used to escape the orchestrated topology and affect the *host* machine of someone
running the samples as documented, that is a genuine report — please send it in.

## What IS in scope here — and high priority

**Anything that makes a sample false-green.** These samples exist to demonstrate
that vouchfx proves a distributed system works; a suite that **passes while the
system under test is actually broken** silently destroys exactly the trust the
samples are meant to build. In-scope, high-priority examples:

- An assertion in a sample suite that cannot fail (wrong table, wrong topic,
  wrong JSONPath, tautological expectation).
- A capture or placeholder that silently defaults so a later step verifies the
  wrong value.
- A sample service change that decouples the asserted side-effect from the
  business transaction (the suite still passes, the transaction no longer works).
- Verdict misclassification in the sample wiring — for example an environment
  error surfacing as a pass.
- A defect in the bootstrap/run scripts (`scripts/`, `ENGINE_PIN`) that runs a
  different engine or suite than the one the output claims — including
  supply-chain tampering with what `bootstrap` fetches and builds.

Report these via **GitHub private vulnerability reporting on this repository**
(**Security → Advisories → Report a vulnerability**,
`https://github.com/tomas-rampas/vouchfx-samples/security/advisories/new`) if there
is a security dimension, or as an ordinary issue if it is purely a correctness bug
with no exploitation angle. When in doubt, use the private route. Response targets
follow the engine's policy: acknowledgement within 3 business days, initial
assessment within 7.

## What belongs in the engine repository

**Genuine vulnerabilities in vouchfx itself** — the engine, the Core providers,
the Provider SDK, or the CI/release templates — belong in the engine repository's
process, even if you discovered them while running these samples. Please follow
the engine's
[SECURITY.md](https://github.com/tomas-rampas/vouchfx/blob/main/SECURITY.md)
(GitHub private vulnerability reporting on the engine repository) rather than
reporting them here. If you are unsure which side owns the issue, report it in the
engine repository and mention the sample that surfaced it; the maintainers overlap
and will route it.

---

_This policy is a living document, aligned with the vouchfx engine's
[security policy](https://github.com/tomas-rampas/vouchfx/blob/main/SECURITY.md)._
