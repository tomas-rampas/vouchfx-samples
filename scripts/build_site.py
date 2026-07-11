#!/usr/bin/env python3
"""Build the vouchfx-samples GitHub Pages site.

Copies the static landing page (site/) into the output directory, then renders
the repository's markdown — the running/custom-runner guides, the four sample
READMEs and the project documents — into styled HTML that matches the engine
and provider-hub project sites. The markdown files remain the single source of
truth; this generates their HTML on every run, so a CI deploy keeps the
published pages current with every push.

    python scripts/build_site.py [output_dir]   # default: _site

Requires: markdown, pygments  (pip install markdown pygments)
"""
from __future__ import annotations

import html
import json
import os
import posixpath
import re
import shutil
import sys
import urllib.request
from pathlib import Path

import markdown
from markdown.extensions.codehilite import CodeHiliteExtension
from markdown.extensions.toc import TocExtension
from pygments.formatters import HtmlFormatter

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
OUT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "_site"

# Markdown files to render, in sidebar order. (source path relative to ROOT, nav group, label)
#
# Every DOCS source path must be matched by a paths: glob in
# .github/workflows/pages.yml (superset invariant) — a page that renders here
# but whose source path a push to main doesn't trigger on would silently drift.
DOCS: list[tuple[str, str, str]] = [
    # Start
    ("docs/RUNNING.md", "Start", "Running the samples"),
    ("docs/custom-runner.md", "Start", "The custom-runner recipe"),

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


def out_path(rel: str) -> Path:
    """Mirror the repo layout under OUT, with .html extension."""
    return OUT / (rel[:-3] + ".html")


def rel_root(target: Path) -> str:
    """Relative path from a generated file back to OUT root, e.g. '../'.
    Forward slashes always, so Windows and CI builds emit identical HTML."""
    rp = os.path.relpath(OUT, target.parent).replace(os.sep, "/")
    return "" if rp == "." else rp + "/"


GITHUB_URL = f"https://github.com/{os.environ.get('GITHUB_REPOSITORY', 'tomas-rampas/vouchfx-samples')}/"
PUBLISHED: set[str] = set()


def compute_published() -> set[str]:
    rels = {rel for rel, _group, _label in DOCS} | set(EXTRA)
    # Auto-render glob stays docs/**/*.md ONLY — never widen this. .vouchfx-src/
    # (the vendored engine checkout) and out/ (run reports) both live on disk
    # in a working copy and must never be swept into the published site.
    for src in ROOT.glob("docs/**/*.md"):
        rel = src.relative_to(ROOT).as_posix()
        if rel not in SKIP and not rel.startswith(SKIP_PREFIXES):
            rels.add(rel)
    return rels


def rewrite_links(body: str, src_rel: str) -> str:
    """Rewrite relative links: published .md pages become .html; any other
    repo-relative target becomes an absolute GitHub URL (it has no page on the
    site). Absolute URLs, anchors and mailto links pass through untouched."""
    src_dir = posixpath.dirname(src_rel)

    def repl(m: re.Match) -> str:
        href = m.group(1)
        if re.match(r"[a-z]+://", href) or href.startswith("#") or href.startswith("mailto:"):
            return m.group(0)
        path, sep, frag = href.partition("#")
        target = posixpath.normpath(posixpath.join(src_dir, path))
        if path.endswith(".md") and target in PUBLISHED:
            return f'href="{path[:-3] + ".html"}{sep}{frag}"'
        kind = "tree" if (ROOT / target).is_dir() else "blob"
        return f'href="{GITHUB_URL}{kind}/main/{target}{sep}{frag}"'

    return re.sub(r'href="([^"]+)"', repl, body)


def extract_mermaid(text: str) -> tuple[str, list[str]]:
    """Pull ```mermaid fenced blocks out before markdown processing."""
    blocks: list[str] = []

    def grab(m: re.Match) -> str:
        blocks.append(m.group(1))
        return f"\n@@MERMAID{len(blocks) - 1}@@\n"

    text = re.sub(r"```mermaid\n(.*?)```", grab, text, flags=re.DOTALL)
    return text, blocks


def sidebar(active_rel: str, root: str) -> str:
    groups: dict[str, list[str]] = {}
    for rel, group, label in DOCS:
        href = root + rel[:-3] + ".html"
        cls = ' class="active"' if rel == active_rel else ""
        groups.setdefault(group, []).append(f'<a href="{href}"{cls}>{html.escape(label)}</a>')
    parts = [f'<a href="{root}docs.html">← All documentation</a>']
    for group, links in groups.items():
        parts.append(f"<h4>{html.escape(group)}</h4>")
        parts.extend(links)
    return "\n".join(parts)


# ---------------------------------------------------------------------------
# Fact injection — self-healing volatile facts
#
# A handful of numbers on the landing page (the latest engine release, the
# published SDK/community-provider versions, the community registry size)
# change on a cadence this repository doesn't control. Rather than let them
# silently drift out of date in hand-written HTML, every page can carry a
# {{fact:KEY}} token that fetch_facts() resolves at build time. Each source
# is independently best-effort: a network hiccup or API shape change falls
# back to the last known-good value in site/facts-fallback.json rather than
# failing the build — a stale fact is a much smaller problem than a broken
# Pages deploy.
# ---------------------------------------------------------------------------

FACT_TOKEN = re.compile(r"\{\{fact:([A-Za-z0-9_]+)\}\}")
FACTS: dict[str, str] = {}


def _fetch_json(url: str, headers: dict[str, str] | None = None):
    req = urllib.request.Request(url, headers=headers or {"User-Agent": "vouchfx-samples-build-site"})
    with urllib.request.urlopen(req, timeout=5) as resp:  # nosec B310 - fixed https URLs only
        return json.loads(resp.read().decode("utf-8"))


def fetch_facts() -> dict[str, str]:
    fallback = json.loads((SITE / "facts-fallback.json").read_text(encoding="utf-8"))
    facts = dict(fallback)
    live: list[str] = []

    try:
        gh_headers = {"User-Agent": "vouchfx-samples-build-site", "Accept": "application/vnd.github+json"}
        token = os.environ.get("GITHUB_TOKEN")
        if token:
            gh_headers["Authorization"] = f"Bearer {token}"
        releases = _fetch_json("https://api.github.com/repos/tomas-rampas/vouchfx/releases", gh_headers)
        facts["engine_release"] = next(r["tag_name"] for r in releases if not r.get("draft"))
        live.append("engine_release")
    except Exception:
        pass

    try:
        data = _fetch_json("https://api.nuget.org/v3-flatcontainer/vouchfx.sdk/index.json")
        facts["sdk_version"] = data["versions"][-1]
        live.append("sdk_version")
    except Exception:
        pass

    try:
        data = _fetch_json("https://api.nuget.org/v3-flatcontainer/vouchfx.community.jsonrpc/index.json")
        facts["community_jsonrpc_version"] = data["versions"][-1]
        live.append("community_jsonrpc_version")
    except Exception:
        pass

    try:
        data = _fetch_json(
            "https://raw.githubusercontent.com/tomas-rampas/vouchfx-providers/main/registry/community-providers.json"
        )
        facts["community_provider_count"] = str(len(data))
        live.append("community_provider_count")
    except Exception:
        pass

    fallback_used = sorted(set(facts) - set(live))
    print(f"facts: live={sorted(live) or ['-']} fallback={fallback_used or ['-']}")
    return facts


def apply_facts(text: str) -> str:
    """Substitute {{fact:KEY}} tokens. Called on site/ HTML right after it is
    copied, and on every rendered page's HTML before it is written."""
    return FACT_TOKEN.sub(lambda m: html.escape(FACTS.get(m.group(1), "")), text)


PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>{title} · vouchfx samples</title>
<meta name="description" content="{desc}" />
<meta name="theme-color" content="#0b0f1a" />
<link rel="icon" href="{root}favicon.svg" type="image/svg+xml" />
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
      <a href="https://tomas-rampas.github.io/vouchfx/">Engine docs</a>
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


def render_markdown(rel: str, label: str) -> None:
    src = ROOT / rel
    text = src.read_text(encoding="utf-8")
    text, mermaid = extract_mermaid(text)

    md = markdown.Markdown(
        extensions=[
            "extra",
            "sane_lists",
            "admonition",
            TocExtension(permalink=True, permalink_class="headerlink", permalink_title="", baselevel=2),
            CodeHiliteExtension(css_class="codehilite", guess_lang=False),
        ]
    )
    body = md.convert(text)
    body = rewrite_links(body, rel)

    # Re-insert mermaid blocks as divs.
    for i, block in enumerate(mermaid):
        body = body.replace(f"<p>@@MERMAID{i}@@</p>", f'<div class="mermaid">{html.escape(block)}</div>')
        body = body.replace(f"@@MERMAID{i}@@", f'<div class="mermaid">{html.escape(block)}</div>')

    toc = getattr(md, "toc", "") or ""
    has_mermaid = bool(mermaid)
    mermaid_script = (
        '<script type="module">import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";'
        'mermaid.initialize({startOnLoad:true,theme:"dark"});</script>'
        if has_mermaid
        else ""
    )

    dst = out_path(rel)
    dst.parent.mkdir(parents=True, exist_ok=True)
    root = rel_root(dst)
    desc = f"vouchfx samples documentation — {label}"
    page = PAGE.format(
        title=html.escape(label),
        desc=html.escape(desc),
        root=root,
        sidebar=sidebar(rel, root),
        crumb=html.escape(label),
        body=body,
        toc=toc,
        mermaid_script=mermaid_script,
    )
    dst.write_text(apply_facts(page), encoding="utf-8")
    print(f"  rendered {rel} -> {dst.relative_to(OUT)}")


PORTAL = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>Documentation · vouchfx samples</title>
<meta name="description" content="vouchfx samples documentation — running the samples, the custom-runner recipe, and every sample's worked-example README." />
<meta name="theme-color" content="#0b0f1a" />
<link rel="icon" href="favicon.svg" type="image/svg+xml" />
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
      <a href="https://tomas-rampas.github.io/vouchfx/">Engine docs</a>
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
      <a class="doc-card" href="https://tomas-rampas.github.io/vouchfx/" target="_blank" rel="noopener noreferrer"><span class="doc-card__k">ENGINE</span><h3>vouchfx project site</h3><p>The architecture blueprint, the YAML DSL specification, and the language reference.</p></a>
      <a class="doc-card" href="https://tomas-rampas.github.io/vouchfx-providers/" target="_blank" rel="noopener noreferrer"><span class="doc-card__k">HUB</span><h3>Provider hub</h3><p>The community provider registry — including rpc.json-rpc, consumed by the ledger-jsonrpc sample.</p></a>
      <a class="doc-card" href="https://github.com/tomas-rampas/vouchfx-telemetry-backend" target="_blank" rel="noopener noreferrer"><span class="doc-card__k">TELEMETRY</span><h3>Telemetry backend</h3><p>The optional, privacy-allowlisted run-metadata aggregation service.</p></a>
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
      <a href="https://tomas-rampas.github.io/vouchfx/" target="_blank" rel="noopener noreferrer">Engine docs</a>
      <a href="https://github.com/tomas-rampas/vouchfx-samples/blob/main/LICENSE" target="_blank" rel="noopener noreferrer">Licence (Apache-2.0)</a>
    </div>
  </div>
</footer>
</body>
</html>
"""


def build_portal() -> None:
    (OUT / "docs.html").write_text(apply_facts(PORTAL), encoding="utf-8")
    print("  built docs.html portal")


def derive_label(src: Path) -> str:
    """Best-effort page label from the first heading, else the file stem."""
    for line in src.read_text(encoding="utf-8").splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return src.stem


def main() -> None:
    # Safety: only ever build into a subdirectory of the repo, never ROOT or an
    # outside path — main() removes OUT with rmtree before rebuilding.
    if OUT == ROOT or ROOT not in OUT.parents:
        raise SystemExit(f"refusing to build into {OUT}: must be a subdirectory of {ROOT}")
    if OUT.exists():
        shutil.rmtree(OUT)
    shutil.copytree(SITE, OUT)
    print(f"copied {SITE.relative_to(ROOT)}/ -> {OUT.name}/")

    # Resolve facts, then substitute {{fact:KEY}} tokens into whatever HTML
    # site/ just copied verbatim (index.html). site/facts-fallback.json itself
    # is build tooling, not a page — it ships inside site/ so it copies above,
    # but has no business being served, so remove the copy once read.
    global FACTS
    FACTS = fetch_facts()
    for html_file in OUT.glob("*.html"):
        html_file.write_text(apply_facts(html_file.read_text(encoding="utf-8")), encoding="utf-8")
    (OUT / "facts-fallback.json").unlink(missing_ok=True)

    # Pygments stylesheet (dark) for fenced code blocks.
    (OUT / "pygments.css").write_text(
        HtmlFormatter(style="monokai").get_style_defs(".codehilite") + "\n.codehilite{background:transparent}",
        encoding="utf-8",
    )

    PUBLISHED.update(compute_published())

    rendered: set[str] = set()
    for rel, _group, label in DOCS:
        render_markdown(rel, label)
        rendered.add(rel)
    for rel in EXTRA:
        if (ROOT / rel).exists():
            render_markdown(rel, derive_label(ROOT / rel))
            rendered.add(rel)

    # Auto-render any markdown under docs/ not explicitly listed, so a newly
    # added file is published (linkable) rather than silently omitted.
    for src in sorted(ROOT.glob("docs/**/*.md")):
        rel = src.relative_to(ROOT).as_posix()
        if rel in rendered or rel in SKIP or rel.startswith(SKIP_PREFIXES):
            continue
        print(f"  (auto) {rel} not in DOCS — rendering with derived label")
        render_markdown(rel, derive_label(src))
        rendered.add(rel)

    build_portal()
    print(f"done -> {OUT}")


if __name__ == "__main__":
    main()
