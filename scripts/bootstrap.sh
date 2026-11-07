#!/usr/bin/env bash
# scripts/bootstrap.sh — fetch the pinned vouchfx engine commit and build its CLI.
#
# Reads the pinned engine commit SHA from ENGINE_PIN at the repo root,
# shallow-fetches exactly that commit from https://github.com/tomas-rampas/vouchfx
# into .vouchfx-src/, and builds the engine CLI
# (src/Cli/Vouchfx.Cli/Vouchfx.Cli.csproj) in Release configuration. Building the
# CLI project performs the NuGet restore that materialises the Aspire AppHost
# SDK's DCP binaries — no separate Aspire workload install is needed.
#
# Idempotent: if .vouchfx-src is already checked out at the pinned SHA, the
# fetch is skipped (the build step still runs, but is a fast no-op incremental
# build).
#
# Usage: scripts/bootstrap.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_REPO_URL="https://github.com/tomas-rampas/vouchfx.git"
VOUCHFX_SRC_DIR="${REPO_ROOT}/.vouchfx-src"
CLI_PROJECT_REL="src/Cli/Vouchfx.Cli/Vouchfx.Cli.csproj"

log() {
  printf '[bootstrap] %s\n' "$1"
}

fail() {
  printf '[bootstrap] ERROR: %s\n' "$1" >&2
  exit 1
}

source_worktree_status() {
  git -C "$VOUCHFX_SRC_DIR" -c core.longpaths=true status --porcelain --untracked-files=all
}

assert_source_checkout() {
  local actual_sha status
  actual_sha="$(git -C "$VOUCHFX_SRC_DIR" -c core.longpaths=true rev-parse HEAD 2>/dev/null)" \
    || fail "Could not read the source checkout commit at ${VOUCHFX_SRC_DIR}."
  [[ "$actual_sha" == "$ENGINE_SHA" ]] \
    || fail "Source checkout at ${VOUCHFX_SRC_DIR} is at ${actual_sha}, expected ${ENGINE_SHA}. Refusing to build an unexpected revision."

  status="$(source_worktree_status)" \
    || fail "Could not inspect the source checkout at ${VOUCHFX_SRC_DIR}."
  [[ -z "$status" ]] \
    || fail "Source checkout at ${VOUCHFX_SRC_DIR} is incomplete or modified. Refusing to build or overwrite it; inspect git status and restore the intended checkout manually."
}

# ── Preflight: required tools ────────────────────────────────────────────────
command -v git >/dev/null 2>&1 \
  || fail "git is not installed or not on PATH. Install it from https://git-scm.com/downloads and re-run."
command -v dotnet >/dev/null 2>&1 \
  || fail ".NET SDK is not installed or not on PATH. Install .NET 8 SDK (8.0.424 or later), .NET 9 or .NET 10 from https://dotnet.microsoft.com/download/dotnet and re-run."
command -v docker >/dev/null 2>&1 \
  || fail "Docker is not installed or not on PATH. Install Docker Desktop (or the Docker Engine) from https://www.docker.com/products/docker-desktop/ — the engine orchestrates test topology via containers and cannot run without it."
docker info >/dev/null 2>&1 \
  || fail "Docker is installed but the daemon is not responding. Start Docker Desktop (or the Docker service) and re-run."

DOTNET_VERSION="$(dotnet --version 2>/dev/null || true)"
log "Using dotnet ${DOTNET_VERSION:-<unknown>}"

# ── Read and validate ENGINE_PIN ─────────────────────────────────────────────
ENGINE_PIN_FILE="${REPO_ROOT}/ENGINE_PIN"
[[ -f "$ENGINE_PIN_FILE" ]] || fail "ENGINE_PIN not found at ${ENGINE_PIN_FILE}."

ENGINE_SHA="$(head -n1 "$ENGINE_PIN_FILE" | tr -d '[:space:]')"

if [[ "$ENGINE_SHA" =~ ^0{40}$ ]]; then
  fail "ENGINE_PIN still holds the placeholder SHA (all zeros). Stamp it with a real 40-character commit SHA from https://github.com/tomas-rampas/vouchfx before running bootstrap."
fi

if ! [[ "$ENGINE_SHA" =~ ^[0-9a-fA-F]{40}$ ]]; then
  fail "ENGINE_PIN's first line ('${ENGINE_SHA}') is not a full 40-character commit SHA. A short SHA or a branch/tag name will not work — shallow cross-repo fetches require the full SHA."
fi

log "Pinned engine commit: ${ENGINE_SHA}"

# ── Fetch the pinned commit (skip if already checked out at that SHA) ───────
CURRENT_SHA=""
if [[ -d "${VOUCHFX_SRC_DIR}/.git" ]]; then
  CURRENT_SHA="$(git -C "$VOUCHFX_SRC_DIR" rev-parse HEAD 2>/dev/null || true)"
fi

if [[ "$CURRENT_SHA" == "$ENGINE_SHA" ]]; then
  log ".vouchfx-src is already at the pinned commit (${ENGINE_SHA:0:12}...) — skipping fetch."
  assert_source_checkout
else
  if [[ -d "$VOUCHFX_SRC_DIR" ]]; then
    status="$(source_worktree_status)" \
      || fail "Could not inspect existing source checkout at ${VOUCHFX_SRC_DIR}; refusing to erase it."
    [[ -z "$status" ]] \
      || fail "Existing source checkout at ${VOUCHFX_SRC_DIR} is modified or incomplete. Refusing to erase it while changing pins; inspect git status and preserve any needed work first."
    log "Removing stale .vouchfx-src (was at ${CURRENT_SHA:-<none>}, pin is ${ENGINE_SHA:0:12}...)."
    rm -rf "$VOUCHFX_SRC_DIR"
  fi

  log "Fetching ${ENGINE_SHA} from ${ENGINE_REPO_URL} (shallow, depth 1)..."
  mkdir -p "$VOUCHFX_SRC_DIR"
  git -C "$VOUCHFX_SRC_DIR" init -q
  git -C "$VOUCHFX_SRC_DIR" remote add origin "$ENGINE_REPO_URL"

  if ! git -C "$VOUCHFX_SRC_DIR" -c core.longpaths=true fetch --depth 1 origin "$ENGINE_SHA"; then
    rm -rf "$VOUCHFX_SRC_DIR"
    fail "Could not fetch commit ${ENGINE_SHA} from ${ENGINE_REPO_URL}. Check the SHA in ENGINE_PIN is correct, reachable in the engine's history, and that you have network access to GitHub."
  fi

  git -C "$VOUCHFX_SRC_DIR" -c core.longpaths=true checkout -q FETCH_HEAD
  log "Checked out ${ENGINE_SHA} into .vouchfx-src/"
  assert_source_checkout
fi

# ── Build the engine CLI ─────────────────────────────────────────────────────
CLI_PROJECT_PATH="${VOUCHFX_SRC_DIR}/${CLI_PROJECT_REL}"
[[ -f "$CLI_PROJECT_PATH" ]] \
  || fail "Expected CLI project not found at ${CLI_PROJECT_PATH}. The engine's repo layout may have changed since this pin was set — check that src/Cli/Vouchfx.Cli/ exists at commit ${ENGINE_SHA}."

log "Building engine CLI (Release)... this also restores the Aspire AppHost SDK's DCP binaries."
# Keep the pinned source immutable while enabling the current runner's
# supported runtime policy, including pins released before major roll-forward.
if ! dotnet build "$CLI_PROJECT_PATH" -c Release -p:RollForward=Major; then
  fail "dotnet build failed for ${CLI_PROJECT_PATH}. See the build output above for details."
fi

log "Bootstrap complete. Engine CLI built from commit ${ENGINE_SHA}."
# Derive the sample list dynamically (mirroring run-sample.sh's list_samples glob —
# portable, no GNU-only `find -printf`) so this hint can never drift from the samples
# the runner actually offers.
sample_hint="$(for d in "${REPO_ROOT}/samples"/*/; do [[ -d "$d" ]] || continue; basename "$d"; done | sort | paste -sd'|' -)"
log "Next: scripts/run-sample.sh <${sample_hint}|all>"
