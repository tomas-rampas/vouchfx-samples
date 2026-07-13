#!/usr/bin/env bash
# scripts/run-migrations.sh — build the shared orders-dotnet image and run all three
# migrations/*/ported suites through the pinned vouchfx engine CLI.
#
# Mirrors scripts/run-sample.sh's conventions: see that file's comments for why every
# failure path returns non-zero instead of calling fail()/exit directly — it lets the
# summary loop below run to completion after a broken migration, and report every result
# rather than stopping at the first failure.
#
# Migrations run strictly sequentially: each suite stands up its own Aspire/Testcontainers
# topology via DCP, and running two topologies concurrently on one machine causes DCP
# port/network contention (see docs/RUNNING.md).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATIONS_DIR="${REPO_ROOT}/migrations"
VOUCHFX_SRC_DIR="${REPO_ROOT}/.vouchfx-src"
CLI_PROJECT="${VOUCHFX_SRC_DIR}/src/Cli/Vouchfx.Cli/Vouchfx.Cli.csproj"
OUT_DIR="${REPO_ROOT}/out"
ORDERS_APP_DIR="${REPO_ROOT}/samples/orders-dotnet/app"
ORDERS_IMAGE="vouchfx-samples-orders-dotnet:local"

log() {
  printf '[run-migrations] %s\n' "$1"
}

fail() {
  printf '[run-migrations] ERROR: %s\n' "$1" >&2
  exit 1
}

# ── Ensure the engine CLI is bootstrapped ────────────────────────────────────
if [[ ! -d "$VOUCHFX_SRC_DIR" ]]; then
  log ".vouchfx-src not found — running scripts/bootstrap.sh first."
  "${REPO_ROOT}/scripts/bootstrap.sh"
fi

[[ -f "$CLI_PROJECT" ]] \
  || fail "Engine CLI project not found at ${CLI_PROJECT} after bootstrap. Re-run scripts/bootstrap.sh and check its output."

mkdir -p "$OUT_DIR"

# ── Build the shared orders-dotnet image, once ───────────────────────────────
# All three migrations port tests against the same samples/orders-dotnet/app, so the image
# is built once here rather than once per migration.
log "=== docker build ${ORDERS_IMAGE} ==="
if ! docker build -t "$ORDERS_IMAGE" "$ORDERS_APP_DIR"; then
  fail "docker build failed for ${ORDERS_IMAGE}."
fi

# migrations/from-postman's ported suite resolves an X-Api-Key header via
# ${secret:env/VOUCHFX_SAMPLES_ORDERS_API_KEY} (secrets resolve from the run environment at
# step-execution time, never at compile time — engine blueprint §17). The orders-dotnet app
# does not itself validate this header — it stands in for a real deployment's API
# gateway/auth proxy. See migrations/from-postman/README.md.
export VOUCHFX_SAMPLES_ORDERS_API_KEY='local-dev-key-not-real'

# run_migration runs a single migrations/<name>/ported suite. It never calls fail()/exit —
# every failure path returns a non-zero status so the summary loop below can continue past
# a broken suite and report a full picture at the end.
run_migration() {
  local name="$1"
  local ported_dir="${MIGRATIONS_DIR}/${name}/ported"
  local junit_out="${OUT_DIR}/migrations-${name}-results.xml"
  local html_out="${OUT_DIR}/migrations-${name}-report.html"

  if [[ ! -d "$ported_dir" ]]; then
    log "Migration '${name}' has no ported/ directory at ${ported_dir}."
    return 1
  fi

  log "=== ${name}: running suite (migrations/${name}/ported) ==="
  local rc=0
  set +e
  dotnet run --project "$CLI_PROJECT" -c Release --no-build -- \
    run "$ported_dir" \
    --junit "$junit_out" \
    --html "$html_out" \
    --fail-on-env-error \
    --fail-on-inconclusive
  rc=$?
  set -e

  log "=== ${name}: exit code ${rc} ==="
  [[ -f "$junit_out" ]] && log "JUnit report: ${junit_out}"
  [[ -f "$html_out" ]] && log "HTML report:  ${html_out}"

  return "$rc"
}

# ── Execute ───────────────────────────────────────────────────────────────────
# Fixed, deliberate order — from-postman first (cheapest, REST-only), then from-xunit, then
# from-specflow (the fullest four-family flow) — rather than a directory listing, so a new
# migrations/<name> directory never silently joins the run before it is ready.
MIGRATIONS=(from-postman from-xunit from-specflow)

SUMMARY_NAMES=()
SUMMARY_RCS=()
OVERALL_RC=0

for name in "${MIGRATIONS[@]}"; do
  rc=0
  run_migration "$name" || rc=$?
  SUMMARY_NAMES+=("$name")
  SUMMARY_RCS+=("$rc")
  if [[ "$rc" -ne 0 ]]; then
    OVERALL_RC=$rc
  fi
done

log "=== Summary ==="
for i in "${!SUMMARY_NAMES[@]}"; do
  log "  ${SUMMARY_NAMES[$i]}: exit ${SUMMARY_RCS[$i]}"
done

exit "$OVERALL_RC"
