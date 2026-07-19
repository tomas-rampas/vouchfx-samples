#!/usr/bin/env python3
"""Build the vouchfx-samples GitHub Pages site.

Copies the static landing page (site/) into the output directory, then renders
the repository's markdown — the running/custom-runner guides, the four sample
READMEs and the project documents — into styled HTML that matches the engine
and provider-hub project sites. The markdown files remain the single source of
truth; this generates their HTML on every run, so a CI deploy keeps the
published pages current with every push.

The rendering machinery is shared with the other three vouchfx sites — see
https://github.com/tomas-rampas/vouchfx/tree/main/scripts/site-tools (the
vouchfx-site-tools package, vouchfx issue #200). This file only carries what
is specific to this repository's own site: the doc set and the page/portal
HTML.

    python scripts/build_site.py [output_dir]   # default: _site

Requires: markdown, pygments, vouchfx-site-tools
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "_site"


def _bootstrap_site_tools() -> None:
    """Resolve vouchfx_site_tools in four steps: (1) an already-installed
    package — this is what CI's pip install satisfies; (2) VOUCHFX_SITE_TOOLS,
    if set, pointing at a scripts/site-tools/src checkout; (3) the maintainer's
    usual local layout, all four repos checked out side by side. Each step is
    tried independently so a wrong VOUCHFX_SITE_TOOLS still falls through to
    the sibling checkout instead of failing outright."""
    try:
        import vouchfx_site_tools  # noqa: F401

        return
    except ImportError:
        pass

    env_path = os.environ.get("VOUCHFX_SITE_TOOLS")
    if env_path:
        sys.path.insert(0, env_path)
        try:
            import vouchfx_site_tools  # noqa: F401

            return
        except ImportError:
            sys.path.pop(0)

    sibling = (ROOT / ".." / "vouchfx" / "scripts" / "site-tools" / "src").resolve()
    sys.path.insert(0, str(sibling))
    try:
        import vouchfx_site_tools  # noqa: F401

        return
    except ImportError:
        sys.path.pop(0)

    raise SystemExit(
        "vouchfx-site-tools is not installed and no local checkout was found.\n"
        "Install it with:\n"
        '  pip install "vouchfx-site-tools @ git+https://github.com/tomas-rampas/vouchfx.git@<sha>'
        '#subdirectory=scripts/site-tools"\n'
        "(substitute <sha> for the pinned commit in .github/workflows/pages.yml), "
        "or set VOUCHFX_SITE_TOOLS to a local scripts/site-tools/src checkout, "
        "or check out vouchfx as a sibling of this repository."
    )


_bootstrap_site_tools()

from vouchfx_site_tools import SiteConfig, build  # noqa: E402

# Markdown files to render, in sidebar order. (source path relative to ROOT, nav group, label)
#
# Every DOCS source path must be matched by a paths: glob in
# .github/workflows/pages.yml (superset invariant) — a page that renders here
# but whose source path a push to main doesn't trigger on would silently drift.
DOCS: list[tuple[str, str, str]] = [
    # Start
    ("docs/RUNNING.md", "Start", "Running the samples"),
    ("docs/custom-runner.md", "Start", "The custom-runner recipe"),
    ("docs/migrating.md", "Start", "Migrating to vouchfx"),

    # Samples
    ("samples/orders-dotnet/README.md", "Samples", "Orders · C# + ASP.NET"),
    ("samples/inventory-python/README.md", "Samples", "Inventory · Python + FastAPI"),
    ("samples/payments-java/README.md", "Samples", "Payments · Java + Spring Boot"),
    ("samples/ledger-jsonrpc/README.md", "Samples", "Ledger · Node.js + JSON-RPC"),

    # Project
    ("README.md", "Project", "Catalogue & repository README"),
    ("CONTRIBUTING.md", "Project", "Contributing a sample"),
    ("SECURITY.md", "Project", "Security policy"),
    ("CODE_OF_CONDUCT.md", "Project", "Code of conduct"),
]

# Any additional markdown that is link-reachable but not in the sidebar.
EXTRA: list[str] = []

# Markdown that must never be published, even when present on a maintainer's
# disk. Nothing in this repository is internal today; the mechanism is kept so
# an accidental future addition fails safe the same way the engine site does.
SKIP: set[str] = set()
SKIP_PREFIXES: tuple[str, ...] = ()

PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>{title} · vouchfx samples</title>
<meta name="description" content="{desc}" />
<meta name="theme-color" content="#0b0f1a" />
<link rel="icon" href="{root}favicon.svg" type="image/svg+xml" />
<link rel="canonical" href="{canonical}" />

<!-- Open Graph / social -->
<meta property="og:type" content="article" />
<meta property="og:site_name" content="vouchfx samples" />
<meta property="og:title" content="{title}" />
<meta property="og:description" content="{desc}" />
<meta property="og:url" content="{canonical}" />

<!-- Twitter card -->
<meta name="twitter:card" content="summary" />
<meta name="twitter:title" content="{title}" />
<meta name="twitter:description" content="{desc}" />

<link rel="stylesheet" href="{root}styles.css" />
<link rel="stylesheet" href="{root}docs.css" />
<link rel="stylesheet" href="{root}pygments.css" />
</head>
<body>
<header class="nav">
  <div class="nav__inner">
    <a class="brand" href="{root}index.html" aria-label="vouchfx samples home">
      <span class="brand__mark" aria-hidden="true"></span>
      <span class="brand__name">vouchfx samples</span>
    </a>
    <nav class="nav__links" aria-label="Primary">
      <a href="{root}index.html">Home</a>
      <a href="{root}docs.html">Docs</a>
      <a href="{root}docs/RUNNING.html">Running the samples</a>
      <a href="https://vouchfx.io/">Engine docs</a>
    </nav>
    <a class="btn btn--ghost nav__gh" href="https://github.com/tomas-rampas/vouchfx-samples" target="_blank" rel="noopener noreferrer">GitHub</a>
  </div>
</header>
<div class="doc-shell">
  <aside class="doc-side">{sidebar}</aside>
  <main class="doc-main">
    <div class="doc-breadcrumb"><a href="{root}docs.html">Documentation</a> / {crumb}</div>
    <article class="prose">{body}</article>
  </main>
  <nav class="doc-toc"><h4>On this page</h4>{toc}</nav>
</div>
{mermaid_script}
</body>
</html>
"""

PORTAL = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>Documentation · vouchfx samples</title>
<meta name="description" content="vouchfx samples documentation — test-suite examples (C#, Python, Node.js, Java) for vouchfx, the end-to-end integration testing framework." />
<meta name="theme-color" content="#0b0f1a" />
<link rel="icon" href="favicon.svg" type="image/svg+xml" />
<link rel="canonical" href="https://samples.vouchfx.io/docs.html" />

<!-- Open Graph / social -->
<meta property="og:type" content="website" />
<meta property="og:site_name" content="vouchfx samples" />
<meta property="og:title" content="Documentation · vouchfx samples" />
<meta property="og:description" content="vouchfx samples documentation — test-suite examples (C#, Python, Node.js, Java) for vouchfx, the end-to-end integration testing framework." />
<meta property="og:url" content="https://samples.vouchfx.io/docs.html" />

<!-- Twitter card -->
<meta name="twitter:card" content="summary" />
<meta name="twitter:title" content="Documentation · vouchfx samples" />
<meta name="twitter:description" content="vouchfx samples documentation — test-suite examples (C#, Python, Node.js, Java) for vouchfx, the end-to-end integration testing framework." />

<link rel="stylesheet" href="styles.css" />
<link rel="stylesheet" href="docs.css" />
</head>
<body>
<header class="nav">
  <div class="nav__inner">
    <a class="brand" href="index.html" aria-label="vouchfx samples home">
      <span class="brand__mark" aria-hidden="true"></span>
      <span class="brand__name">vouchfx samples</span>
    </a>
    <nav class="nav__links" aria-label="Primary">
      <a href="index.html">Home</a>
      <a href="docs/RUNNING.html">Running the samples</a>
      <a href="https://vouchfx.io/">Engine docs</a>
    </nav>
    <a class="btn btn--ghost nav__gh" href="https://github.com/tomas-rampas/vouchfx-samples" target="_blank" rel="noopener noreferrer">GitHub</a>
  </div>
</header>
<div class="container portal">
  <div class="portal__head">
    <p class="eyebrow">Documentation</p>
    <h1 class="section__title">Four samples, four stacks, one engine.</h1>
    <p class="section__lede">These pages are rendered straight from the repository's markdown on every push,
      so they never drift from the code they describe.</p>
  </div>

  <section class="portal__group">
    <h2>Start here</h2>
    <p>Prerequisites, the two-command quick start, and how to read a result.</p>
    <div class="doc-cards">
      <a class="doc-card" href="docs/RUNNING.html">
        <span class="doc-card__k">1 · GUIDE</span><h3>Running the samples</h3>
        <p>What you need installed, the two-command quick start, the four-verdict taxonomy and exit codes, and what CI does differently from your machine.</p>
      </a>
      <a class="doc-card" href="docs/custom-runner.html">
        <span class="doc-card__k">2 · RECIPE</span><h3>The custom-runner recipe</h3>
        <p>How to consume a Community-tier provider today: build a thin executable over the engine's public SDK, referencing exactly the providers you need.</p>
      </a>
      <a class="doc-card" href="docs/migrating.html">
        <span class="doc-card__k">3 · GUIDE</span><h3>Migrating to vouchfx</h3>
        <p>Three worked examples — Postman, xUnit, SpecFlow — each re-authored (not auto-converted) onto the orders-dotnet sample, with a field-by-field mapping table and an honest account of what doesn't map.</p>
      </a>
    </div>
  </section>

  <section class="portal__group">
    <h2>The samples</h2>
    <p>Each is a real service with its own database, broker, or cache — not a toy echo.</p>
    <div class="doc-cards">
      <a class="doc-card" href="samples/orders-dotnet/README.html">
        <span class="doc-card__k">C# · ASP.NET CORE 8</span><h3>Orders</h3>
        <p>REST → Postgres row → Kafka event → outbound webhook callback. Five steps.</p>
      </a>
      <a class="doc-card" href="samples/inventory-python/README.html">
        <span class="doc-card__k">PYTHON · FASTAPI</span><h3>Inventory</h3>
        <p>REST → MySQL row → Redis cache entry → RabbitMQ event, with a read-through cache proof. Five steps.</p>
      </a>
      <a class="doc-card" href="samples/payments-java/README.html">
        <span class="doc-card__k">JAVA · SPRING BOOT 3.3</span><h3>Payments</h3>
        <p>REST → SQL Server row → NATS JetStream event → SMTP receipt e-mail. Four steps.</p>
      </a>
      <a class="doc-card" href="samples/ledger-jsonrpc/README.html">
        <span class="doc-card__k">NODE.JS · JSON-RPC 2.0</span><h3>Ledger</h3>
        <p>JSON-RPC → Postgres → Kafka → an independent worker role consuming an injected adjustment, via a custom runner and the Community rpc.json-rpc provider. Ten steps.</p>
      </a>
    </div>
  </section>

  <section class="portal__group">
    <h2>Project</h2>
    <p>How this repository is run.</p>
    <div class="doc-cards">
      <a class="doc-card" href="README.html"><span class="doc-card__k">README</span><h3>Catalogue & repository README</h3><p>Overview, the sample catalogue table, quick start, and directory layout.</p></a>
      <a class="doc-card" href="CONTRIBUTING.html"><span class="doc-card__k">HOW</span><h3>Contributing a sample</h3><p>The quality bar for a new sample, and how to add one.</p></a>
      <a class="doc-card" href="SECURITY.html"><span class="doc-card__k">SEC</span><h3>Security policy</h3><p>How to report a vulnerability in a sample application or test suite.</p></a>
      <a class="doc-card" href="CODE_OF_CONDUCT.html"><span class="doc-card__k">CoC</span><h3>Code of conduct</h3><p>The standards this community holds itself to.</p></a>
    </div>
  </section>

  <section class="portal__group">
    <h2>Ecosystem</h2>
    <p>Where the pieces this repository depends on live.</p>
    <div class="doc-cards">
      <a class="doc-card" href="https://vouchfx.io/" target="_blank" rel="noopener noreferrer"><span class="doc-card__k">ENGINE</span><h3>vouchfx project site</h3><p>The architecture blueprint, the YAML DSL specification, and the language reference.</p></a>
      <a class="doc-card" href="https://providers.vouchfx.io/" target="_blank" rel="noopener noreferrer"><span class="doc-card__k">HUB</span><h3>Provider hub</h3><p>The community provider registry — including rpc.json-rpc, consumed by the ledger-jsonrpc sample.</p></a>
      <a class="doc-card" href="https://telemetry.vouchfx.io/" target="_blank" rel="noopener noreferrer"><span class="doc-card__k">TELEMETRY</span><h3>Telemetry backend</h3><p>The optional, privacy-allowlisted run-metadata aggregation service.</p></a>
    </div>
  </section>
</div>

<footer class="footer">
  <div class="container footer__inner">
    <div class="footer__brand">
      <span class="brand__mark" aria-hidden="true"></span>
      <div><strong>vouchfx samples</strong><p>Real-world working samples for the vouchfx engine — four production-shaped applications, four stacks, one coherent business transaction proven end-to-end in each.</p></div>
    </div>
    <div class="footer__links">
      <a href="index.html">Home</a>
      <a href="https://github.com/tomas-rampas/vouchfx-samples" target="_blank" rel="noopener noreferrer">Repository</a>
      <a href="https://vouchfx.io/" target="_blank" rel="noopener noreferrer">Engine docs</a>
      <a href="https://github.com/tomas-rampas/vouchfx-samples/blob/main/LICENSE" target="_blank" rel="noopener noreferrer">Licence (Apache-2.0)</a>
    </div>
  </div>
</footer>
</body>
</html>
"""

CONFIG = SiteConfig(
    root=ROOT,
    default_repo="tomas-rampas/vouchfx-samples",
    docs=DOCS,
    page_template=PAGE,
    portal_html=PORTAL,
    meta_description_prefix="vouchfx samples — test-suite examples for vouchfx, the end-to-end integration testing framework",
    extra=EXTRA,
    skip=SKIP,
    skip_prefixes=SKIP_PREFIXES,
    # specs/seo-custom-domains.md REQ-006: this repo's custom domain. Opts build()
    # into emitting robots.txt + sitemap.xml and supplying {canonical} to PAGE.
    site_url="https://samples.vouchfx.io/",
)


def main() -> None:
    build(CONFIG, OUT)


if __name__ == "__main__":
    main()
