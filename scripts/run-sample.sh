#!/usr/bin/env bash
# scripts/run-sample.sh — build a sample's Docker image and run its .e2e.yaml
# suite through the pinned vouchfx engine CLI.
#
# Usage:
#   scripts/run-sample.sh <sample-name>   # e.g. orders-dotnet
#   scripts/run-sample.sh all             # every sample, one at a time
#
# Samples run strictly sequentially, even under "all": each suite stands up
# its own Aspire/Testcontainers topology via DCP, and running two topologies
# concurrently on one machine causes DCP port/network contention (see
# docs/RUNNING.md).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAMPLES_DIR="${REPO_ROOT}/samples"
VOUCHFX_SRC_DIR="${REPO_ROOT}/.vouchfx-src"
CLI_PROJECT="${VOUCHFX_SRC_DIR}/src/Cli/Vouchfx.Cli/Vouchfx.Cli.csproj"
OUT_DIR="${REPO_ROOT}/out"

# ── Build-time network accommodations (all opt-in) ────────────────────────────
# With none of the variables below set, the `docker build` invocation is exactly
# what it has always been — these exist for restricted networks (an egress proxy,
# an air-gapped CI sandbox) where the default build cannot reach the internet.
# scripts/run-migrations.sh carries the identical block; keep the two in step.
#
#   VOUCHFX_SAMPLES_NO_BUILDKIT=1
#       Build with the legacy builder. BuildKit honours the
#       `# syntax=docker/dockerfile:1` directive by first pulling that frontend
#       image from Docker Hub, which fails before the build even starts on a
#       network that cannot reach Docker Hub. The legacy builder skips it.
#
#   VOUCHFX_SAMPLES_BUILD_NETWORK=<network>
#       Passed through as `docker build --network <network>`. Use "host" when the
#       build must reach a proxy bound to the host's loopback address: a build
#       container on the default bridge network has its own 127.0.0.1 and cannot
#       see the host's.
#
#   HTTPS_PROXY / HTTP_PROXY / NO_PROXY (and lower-case forms)
#       Forwarded as build args when present in the environment. Docker
#       predefines these as build args, so no Dockerfile `ARG` is required and
#       their values are kept out of `docker history`.
#
# Pulling the *dependency* images (postgres, kafka, ...) is not something this
# script controls — Aspire/DCP pulls those itself at run time. Point the Docker
# daemon at a registry mirror instead (docs/RUNNING.md, "Restricted networks").
if [[ "${VOUCHFX_SAMPLES_NO_BUILDKIT:-0}" == "1" ]]; then
  export DOCKER_BUILDKIT=0
fi

# docker_build_flags emits one extra `docker build` argument per line (nothing at
# all when no accommodation is configured). Line-per-argument keeps values with
# spaces intact when the caller reads them back into an array.
docker_build_flags() {
  local var
  if [[ -n "${VOUCHFX_SAMPLES_BUILD_NETWORK:-}" ]]; then
    printf '%s\n' '--network' "${VOUCHFX_SAMPLES_BUILD_NETWORK}"
  fi
  for var in HTTPS_PROXY HTTP_PROXY NO_PROXY https_proxy http_proxy no_proxy; do
    # ${!var} is an indirect expansion: the value of the variable *named* by $var.
    if [[ -n "${!var:-}" ]]; then
      printf '%s\n' '--build-arg' "${var}=${!var}"
    fi
  done
}

log() {
  printf '[run-sample] %s\n' "$1"
}

fail() {
  printf '[run-sample] ERROR: %s\n' "$1" >&2
  exit 1
}

# list_samples prints the basename of every directory under samples/, sorted.
# Implemented with a glob (not `find -printf`, which is a GNU-only extension)
# so it works on both GNU/Linux and BSD-userland macOS.
list_samples() {
  local d
  for d in "$SAMPLES_DIR"/*/; do
    [[ -d "$d" ]] || continue
    basename "$d"
  done | sort
}

usage() {
  printf 'Usage: %s <sample-name>|all\n\n' "$0" >&2
  printf 'Available samples:\n' >&2
  list_samples | sed 's/^/  - /' >&2
  printf '  - all   (run every sample above, one at a time)\n' >&2
}

# ── Argument validation ───────────────────────────────────────────────────────
if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

TARGET="$1"

AVAILABLE_SAMPLES=()
while IFS= read -r name; do
  [[ -n "$name" ]] && AVAILABLE_SAMPLES+=("$name")
done < <(list_samples)

if [[ "$TARGET" != "all" ]]; then
  found=0
  for s in "${AVAILABLE_SAMPLES[@]}"; do
    if [[ "$s" == "$TARGET" ]]; then
      found=1
      break
    fi
  done
  if [[ "$found" -ne 1 ]]; then
    printf '[run-sample] ERROR: unknown sample "%s"\n\n' "$TARGET" >&2
    usage
    exit 2
  fi
fi

# ── Ensure the engine CLI is bootstrapped, AT THE PINNED COMMIT ──────────────
# Presence of .vouchfx-src is not enough: an existing checkout can be sitting at
# a PREVIOUS pin, and then every suite here runs against the wrong engine while
# reporting success. That is not hypothetical — advancing ENGINE_PIN to
# v1.0.0-rc.5 and re-running produced a schema rejection of a field the pinned
# engine supports, because the stale checkout was still at rc.4. ENGINE_PIN's
# own instructions say to delete .vouchfx-src by hand; a step nobody can forget
# is better than a step everybody must remember.
pinned_sha="$(grep -m1 -E '^[0-9a-f]{40}$' "${REPO_ROOT}/ENGINE_PIN" || true)"
checkout_sha=""
if [[ -d "$VOUCHFX_SRC_DIR/.git" ]]; then
  checkout_sha="$(git -C "$VOUCHFX_SRC_DIR" rev-parse HEAD 2>/dev/null || true)"
fi

if [[ ! -d "$VOUCHFX_SRC_DIR" ]]; then
  log ".vouchfx-src not found — running scripts/bootstrap.sh first."
  "${REPO_ROOT}/scripts/bootstrap.sh"
elif [[ -n "$pinned_sha" && "$checkout_sha" != "$pinned_sha" ]]; then
  log ".vouchfx-src is at ${checkout_sha:-<unknown>} but ENGINE_PIN says ${pinned_sha}."
  log "Re-bootstrapping so this run uses the pinned engine, not the stale one."
  rm -rf "$VOUCHFX_SRC_DIR"
  "${REPO_ROOT}/scripts/bootstrap.sh"
fi

[[ -f "$CLI_PROJECT" ]] \
  || fail "Engine CLI project not found at ${CLI_PROJECT} after bootstrap. Re-run scripts/bootstrap.sh and check its output."

mkdir -p "$OUT_DIR"

# has_runner_project reports whether samples/<name>/runner contains a
# .csproj — signalling a sample with a custom Aspire-hosted runner (e.g. one
# consuming a community provider not yet vendored into engine Core) instead
# of the standard CLI-only invocation. Same defensive glob idiom as
# list_samples above (no nullglob needed): an unmatched glob stays literal
# and just fails the -f test.
has_runner_project() {
  local dir="$1"
  local f
  for f in "$dir"/*.csproj; do
    [[ -f "$f" ]] && return 0
  done
  return 1
}

# run_one builds and tests a single sample. It never calls fail()/exit — every
# failure path returns a non-zero status so the "all" loop can continue past a
# broken sample and report a full summary at the end.
run_one() {
  local name="$1"
  local image="vouchfx-samples-${name}:local"
  local app_dir="${SAMPLES_DIR}/${name}/app"
  local tests_dir="${SAMPLES_DIR}/${name}/tests"
  local runner_dir="${SAMPLES_DIR}/${name}/runner"
  local setup_script="${SAMPLES_DIR}/${name}/setup.sh"
  local junit_out="${OUT_DIR}/${name}-results.xml"
  local html_out="${OUT_DIR}/${name}-report.html"

  if [[ ! -d "$tests_dir" ]]; then
    log "Sample '${name}' has no tests/ directory at ${tests_dir}."
    return 1
  fi

  # Discovered by CONVENTION, not listed by name: a sample that declares
  # certificates or other files a fresh checkout does not contain (a
  # `security:` block's `caCert`/`clientCert`/`clientKey`/`serverArtifacts`,
  # all resolved and existence-checked before any container starts) ships
  # samples/<name>/setup.sh beside its suite. This is the only point at which
  # such material can be created — nothing inside the suite itself can, since
  # every declared path is checked before the topology starts (see
  # samples/kafka-mtls/README.md for the concrete case this exists for).
  # Mirrors examples/<name>.setup.sh discovery in the engine's own
  # vouchfx-run-examples.yml CI workflow. Absent for every sample that needs
  # no generated fixtures, which is most of them.
  if [[ -f "$setup_script" ]]; then
    log "=== ${name}: running setup script (samples/${name}/setup.sh) ==="
    if ! bash "$setup_script"; then
      log "setup.sh failed for ${name}."
      return 1
    fi
  fi

  # A sample with no system under test — only managed dependencies and steps
  # against them — has no app/ directory and needs no image built. Tolerated
  # rather than required: only has_runner_project below or the CLI-only path
  # further down actually needs anything docker-built here.
  local has_app=0
  if [[ -d "$app_dir" ]]; then
    has_app=1
  else
    log "Sample '${name}' has no app/ directory — skipping docker build (no system under test)."
  fi

  local rc=0

  if [[ "$has_app" -eq 1 ]]; then
    log "=== ${name}: docker build ${image} ==="
    # Read the opt-in flags into an array one line at a time, so a value containing
    # spaces survives intact (word-splitting an unquoted string would not).
    local -a build_flags=()
    while IFS= read -r flag; do
      [[ -n "$flag" ]] && build_flags+=("$flag")
    done < <(docker_build_flags)
    # ${arr[@]+"${arr[@]}"} expands to nothing at all when the array is empty,
    # instead of tripping `set -u` on bash 3.2 (still the system bash on macOS).
    if ! docker build ${build_flags[@]+"${build_flags[@]}"} -t "$image" "$app_dir"; then
      log "docker build failed for ${name}."
      return 1
    fi
  fi

  if has_runner_project "$runner_dir"; then
    # Custom-runner sample: it project-references the bootstrapped
    # .vouchfx-src checkout, already guaranteed present by the auto-bootstrap
    # gate above (run once, before any run_one call, regardless of target).
    # Build it, then invoke it directly — its exit codes (0/1/3/4) are
    # already taxonomy-strict, so it takes no --fail-on-* flags.
    log "=== ${name}: building runner (samples/${name}/runner) ==="
    if ! dotnet build "$runner_dir" -c Release; then
      log "dotnet build failed for ${name} runner."
      return 1
    fi

    log "=== ${name}: running suite via runner (samples/${name}/tests) ==="
    set +e
    dotnet run --project "$runner_dir" -c Release --no-build -- \
      "$tests_dir" \
      --junit "$junit_out" \
      --html "$html_out"
    rc=$?
    set -e
  else
    log "=== ${name}: running suite (samples/${name}/tests) ==="
    set +e
    dotnet run --project "$CLI_PROJECT" -c Release --no-build -- \
      run "$tests_dir" \
      --junit "$junit_out" \
      --html "$html_out" \
      --fail-on-env-error \
      --fail-on-inconclusive
    rc=$?
    set -e
  fi

  log "=== ${name}: exit code ${rc} ==="
  [[ -f "$junit_out" ]] && log "JUnit report: ${junit_out}"
  [[ -f "$html_out" ]] && log "HTML report:  ${html_out}"

  return "$rc"
}

# ── Execute ───────────────────────────────────────────────────────────────────
if [[ "$TARGET" == "all" ]]; then
  TARGETS=("${AVAILABLE_SAMPLES[@]}")
else
  TARGETS=("$TARGET")
fi

SUMMARY_NAMES=()
SUMMARY_RCS=()
OVERALL_RC=0

for name in "${TARGETS[@]}"; do
  rc=0
  run_one "$name" || rc=$?
  SUMMARY_NAMES+=("$name")
  SUMMARY_RCS+=("$rc")
  if [[ "$rc" -ne 0 ]]; then
    OVERALL_RC=$rc
  fi
done

if [[ "${#TARGETS[@]}" -gt 1 ]]; then
  log "=== Summary ==="
  for i in "${!SUMMARY_NAMES[@]}"; do
    log "  ${SUMMARY_NAMES[$i]}: exit ${SUMMARY_RCS[$i]}"
  done
fi

exit "$OVERALL_RC"
