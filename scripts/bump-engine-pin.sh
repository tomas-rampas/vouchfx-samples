#!/usr/bin/env bash
# scripts/bump-engine-pin.sh — resolve a vouchfx tag/branch/SHA to its full
# commit SHA and write it into ENGINE_PIN, so a human never has to hand-copy
# (and risk mis-copying, or copying an annotated tag's own SHA instead of the
# commit it points at) a 40-character hex string.
#
# This is a SEMI-automatic helper, not full automation: it still requires a
# human (or an agent acting on a human's request) to run it, review the
# resulting diff, and open the pin-bump PR — ENGINE_PIN's own documented
# philosophy ("a deliberate, reviewed action") is unchanged. It just removes
# the error-prone manual-lookup step.
#
# Usage:
#   scripts/bump-engine-pin.sh <tag-or-branch-or-sha> ["reason for the bump"]
#
# Examples:
#   scripts/bump-engine-pin.sh v1.0.0-alpha.5 "script.csharp file field (engine PR #194)"
#   scripts/bump-engine-pin.sh a24a3f5beae0ff78ba97b69ab1f2fefa4d7eff99
#
# What it does:
#   1. Resolves <tag-or-branch-or-sha> to a full 40-char commit SHA via
#      `git ls-remote` against https://github.com/tomas-rampas/vouchfx — no
#      local clone needed. Annotated tags are peeled (^{}) automatically, so
#      you always get the COMMIT sha, never the tag object's own sha.
#   2. Refuses to proceed if the resolved value isn't a full 40-hex-char SHA,
#      or if it's identical to the SHA already pinned (nothing to do).
#   3. Rewrites ENGINE_PIN's first line with the new SHA and appends a dated
#      "Pin history" entry recording the old SHA, the new SHA, and the reason
#      you supplied (or a placeholder reminding you to fill it in).
#   4. Does NOT fetch/build/commit/push/open a PR — that remains a deliberate
#      follow-up step (see ENGINE_PIN's "How to advance it").
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_REPO_URL="https://github.com/tomas-rampas/vouchfx.git"
ENGINE_PIN_FILE="${REPO_ROOT}/ENGINE_PIN"

log() {
  printf '[bump-engine-pin] %s\n' "$1"
}

fail() {
  printf '[bump-engine-pin] ERROR: %s\n' "$1" >&2
  exit 1
}

[[ $# -ge 1 ]] || fail "usage: scripts/bump-engine-pin.sh <tag-or-branch-or-sha> [\"reason\"]"
REF="$1"
REASON="${2:-<fill in why this pin was advanced>}"

command -v git >/dev/null 2>&1 || fail "git is not installed or not on PATH."
[[ -f "$ENGINE_PIN_FILE" ]] || fail "ENGINE_PIN not found at ${ENGINE_PIN_FILE}."

OLD_SHA="$(head -n1 "$ENGINE_PIN_FILE" | tr -d '[:space:]')"

# ── Resolve REF to a full commit SHA ─────────────────────────────────────────
NEW_SHA=""

if [[ "$REF" =~ ^[0-9a-fA-F]{40}$ ]]; then
  # Already a full SHA — use as-is (still validated for fetchability by
  # scripts/bootstrap.sh later; this script only handles the lookup/write).
  NEW_SHA="$REF"
else
  log "Resolving '${REF}' against ${ENGINE_REPO_URL} ..."

  # Try an ANNOTATED tag first: refs/tags/<REF>^{} peels to the commit the
  # tag points at (not the tag object's own SHA, which ENGINE_PIN must never
  # hold — bootstrap.sh checks out the pin with a plain commit fetch).
  PEELED="$(git ls-remote --tags "$ENGINE_REPO_URL" "refs/tags/${REF}^{}" 2>/dev/null | awk '{print $1}')"

  if [[ -n "$PEELED" ]]; then
    NEW_SHA="$PEELED"
  else
    # Fall back to a lightweight tag, or a branch name (branches are
    # discouraged as a lasting pin per ENGINE_PIN's own rationale, but
    # resolving one here is still useful to seed a one-off lookup).
    PLAIN="$(git ls-remote "$ENGINE_REPO_URL" "$REF" 2>/dev/null | awk '{print $1}' | head -n1)"
    [[ -n "$PLAIN" ]] && NEW_SHA="$PLAIN"
  fi
fi

[[ -n "$NEW_SHA" ]] || fail "Could not resolve '${REF}' to a commit on ${ENGINE_REPO_URL}. Check the tag/branch name is correct and pushed."
[[ "$NEW_SHA" =~ ^[0-9a-fA-F]{40}$ ]] || fail "Resolved value '${NEW_SHA}' is not a full 40-character commit SHA."

if [[ "$NEW_SHA" == "$OLD_SHA" ]]; then
  log "ENGINE_PIN is already at ${NEW_SHA} — nothing to do."
  exit 0
fi

log "Old pin: ${OLD_SHA}"
log "New pin: ${NEW_SHA}  (resolved from '${REF}')"

# ── Rewrite ENGINE_PIN ────────────────────────────────────────────────────────
TODAY="$(date -u +%Y-%m-%d)"
TMP_FILE="$(mktemp)"

{
  echo "$NEW_SHA"
  tail -n +2 "$ENGINE_PIN_FILE"
} > "$TMP_FILE"

# Append the new history entry directly under the "Pin history" heading so
# newest-first ordering matches every existing entry in the file.
awk -v today="$TODAY" -v new_sha="${NEW_SHA:0:8}" -v old_sha="${OLD_SHA:0:8}" -v reason="$REASON" '
  { print }
  /^# Pin history$/ { getline sep; print sep; print "# " today ": advanced to " new_sha " — " reason "."; print "# Prior pin: " old_sha "."; next }
' "$TMP_FILE" > "${TMP_FILE}.history" && mv "${TMP_FILE}.history" "$TMP_FILE"

mv "$TMP_FILE" "$ENGINE_PIN_FILE"

log "ENGINE_PIN updated. Review the diff, then follow ENGINE_PIN's remaining steps:"
log "  1. rm -rf .vouchfx-src"
log "  2. scripts/run-sample.sh all   (or .ps1 on Windows)"
log "  3. Open a PR with just the pin bump (plus any required sample changes)."
