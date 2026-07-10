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

# ── Ensure the engine CLI is bootstrapped ────────────────────────────────────
if [[ ! -d "$VOUCHFX_SRC_DIR" ]]; then
  log ".vouchfx-src not found — running scripts/bootstrap.sh first."
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
  local junit_out="${OUT_DIR}/${name}-results.xml"
  local html_out="${OUT_DIR}/${name}-report.html"

  if [[ ! -d "$app_dir" ]]; then
    log "Sample '${name}' has no app/ directory at ${app_dir}."
    return 1
  fi
  if [[ ! -d "$tests_dir" ]]; then
    log "Sample '${name}' has no tests/ directory at ${tests_dir}."
    return 1
  fi

  log "=== ${name}: docker build ${image} ==="
  if ! docker build -t "$image" "$app_dir"; then
    log "docker build failed for ${name}."
    return 1
  fi

  local rc=0

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
