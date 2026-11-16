#!/usr/bin/env bash
# Regression tests for the global.json guard in .claude/hooks/session-start.sh.
#
# global_json_safe (and log) are extracted from the REAL hook file at test time; the rest of
# the hook is never executed. Every case runs under both LC_ALL=C and LC_ALL=C.UTF-8,
# because a guard that counts characters instead of bytes is bypassed by a file of
# multi-byte text larger than its size limit.
#
# An accepted file must produce no output. A refused file must exit non-zero, write exactly
# one "ERROR" line to stderr and nothing to stdout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HOOK="${REPO_ROOT}/.claude/hooks/session-start.sh"
TEMP_ROOT="$(cd "${TMPDIR:-/tmp}" && pwd)"
SCRATCH="$(mktemp -d "${TEMP_ROOT}/vouchfx-guard-tests.XXXXXX")"
PASSED=0
TOTAL=0

cleanup() {
  case "$SCRATCH" in
    "${TEMP_ROOT}"/vouchfx-guard-tests.*) rm -rf "$SCRATCH" ;;
    *) printf 'Refusing to remove unexpected scratch path: %s\n' "$SCRATCH" >&2; exit 1 ;;
  esac
}
trap cleanup EXIT

die() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Pull one function out of the hook: from "name() {" to the first line that is just "}".
extract_function() {
  awk -v name="$1" '
    $0 ~ "^" name "\\(\\) \\{" { on = 1 }
    on { print }
    on && $0 == "}" { exit }
  ' "$HOOK"
}

[[ -f "$HOOK" ]] || die "hook not found at ${HOOK}"
LIB="${SCRATCH}/guard-lib.sh"
{
  grep -E '^log\(\) \{' "$HOOK"
  extract_function global_json_safe
} >"$LIB"
grep -q '^log() {' "$LIB" || die 'could not extract log from the hook'
grep -q '^global_json_safe() {' "$LIB" || die 'could not extract global_json_safe from the hook'
[[ "$(tail -n1 "$LIB")" == '}' ]] || die 'global_json_safe was not extracted completely'

# Runs the guard on one file in a fresh shell, with the hook's own shell options and the
# given locale. Sets RC, OUT and ERR.
run_guard() {
  local locale="$1" file="$2"
  RC=0
  # The script is single-quoted on purpose: the child shell expands $1 and $2.
  # shellcheck disable=SC2016
  LC_ALL="$locale" timeout 10 bash -c 'set -euo pipefail; REPO_DIR=/nonexistent; source "$1"; global_json_safe "$2"' \
    guard "$LIB" "$file" >"${SCRATCH}/out" 2>"${SCRATCH}/err" || RC=$?
  OUT="$(cat "${SCRATCH}/out")"
  ERR="$(cat "${SCRATCH}/err")"
}

expect_accept() {
  local name="$1" file="$2" locale
  for locale in C C.UTF-8; do
    TOTAL=$((TOTAL + 1))
    run_guard "$locale" "$file"
    [[ "$RC" -eq 0 ]] || die "${name} (${locale}): expected accept, got exit ${RC}: ${ERR}"
    [[ -z "$OUT" && -z "$ERR" ]] || die "${name} (${locale}): an accepted file must print nothing (stdout: ${OUT}; stderr: ${ERR})"
    PASSED=$((PASSED + 1))
  done
}

expect_refuse() {
  local name="$1" file="$2" locale lines
  for locale in C C.UTF-8; do
    TOTAL=$((TOTAL + 1))
    run_guard "$locale" "$file"
    [[ "$RC" -ne 0 ]] || die "${name} (${locale}): the guard ACCEPTED a file it must refuse"
    [[ "$RC" -ne 124 ]] || die "${name} (${locale}): the guard did not finish within 10 seconds"
    [[ -z "$OUT" ]] || die "${name} (${locale}): a refusal must not write to stdout: ${OUT}"
    lines="$(printf '%s\n' "$ERR" | grep -c .)"
    [[ "$lines" -eq 1 && "$ERR" == *'ERROR'* ]] || die "${name} (${locale}): expected exactly one ERROR line on stderr, got: ${ERR}"
    PASSED=$((PASSED + 1))
  done
}

fixture() { printf '%s/%s' "$SCRATCH" "$1"; }
# Repeats a string $2 times.
repeat() { local i out=''; for ((i = 0; i < $2; i++)); do out+="$1"; done; printf '%s' "$out"; }

GOOD='{"sdk":{"version":"10.0.100","rollForward":"latestFeature"}}'
EVIL_SDK='"sdk":{"paths":[".evil"],"version":"10.0.100"}'

# ---- accepted ----
expect_accept 'the repository global.json' "${REPO_ROOT}/global.json"

printf '{\r\n  "sdk": {\r\n    "version": "10.0.100",\r\n    "rollForward": "latestFeature",\r\n    "allowPrerelease": false\r\n  }\r\n}\r\n' >"$(fixture crlf.json)"
expect_accept 'a CRLF pretty-printed file' "$(fixture crlf.json)"

printf '{\n  "msbuild-sdks": { "Example.Build.Sdk": "1.0.0" },\n  "sdk": { "version": "10.0.100" }\n}\n' >"$(fixture other-key.json)"
expect_accept 'a file with another top-level key' "$(fixture other-key.json)"

# ---- refused: the file itself ----
expect_refuse 'a missing file' "$(fixture does-not-exist.json)"

printf '%s\n' "$GOOD" >"$(fixture valid.json)"
ln -s "$(fixture valid.json)" "$(fixture link-to-valid.json)"
expect_refuse 'a symlink to a valid file' "$(fixture link-to-valid.json)"

ln -s /dev/zero "$(fixture link-to-zero.json)"
expect_refuse 'a symlink to /dev/zero' "$(fixture link-to-zero.json)"

mkdir "$(fixture a-directory)"
expect_refuse 'a directory' "$(fixture a-directory)"

: >"$(fixture empty.json)"
expect_refuse 'an empty file' "$(fixture empty.json)"

# ---- refused: the SDK entry ----
printf '{"sdk":{"paths":[".evil"],"version":"10.0.100"}}\n' >"$(fixture paths.json)"
expect_refuse 'sdk.paths' "$(fixture paths.json)"

printf '{"sdk":{"version":"10.0.100","errorMessage":"x"}}\n' >"$(fixture error-message.json)"
expect_refuse 'sdk.errorMessage' "$(fixture error-message.json)"

printf '{"sdk":{"version":"10.0.100"},"sdk":{"paths":[".evil"]}}\n' >"$(fixture duplicate.json)"
expect_refuse 'a duplicate sdk entry' "$(fixture duplicate.json)"

printf '// "sdk": { "version": "10.0.100" }\n{"sdk":{"paths":[".evil"],"version":"10.0.100"}}\n' >"$(fixture comment.json)"
expect_refuse 'a // comment holding a benign sdk entry' "$(fixture comment.json)"

# ---- refused: size and bytes ----
{ printf '{"pad":"'; repeat a 102400; printf '","sdk":{"version":"10.0.100"}}\n'; } >"$(fixture ascii-100k.json)"
expect_refuse 'a 100 KiB ASCII file' "$(fixture ascii-100k.json)"

# The bypass: more than 64 KiB of multi-byte text, so a character count is below the limit
# while the byte count is above it, and the real "sdk" entry comes after the truncation.
{
  printf '{"other":{"sdk":{"version":"10.0.100"}},"pad":"'
  repeat é 40000
  printf '",%s}\n' "$EVIL_SDK"
} >"$(fixture multibyte-bypass.json)"
expect_refuse 'the multi-byte padded bypass file' "$(fixture multibyte-bypass.json)"

# Variant: a benign "sdk" in a comment, then padding, then the real entry.
{
  printf '// "sdk": { "version": "10.0.100" }\n{"pad":"'
  repeat é 40000
  printf '",%s}\n' "$EVIL_SDK"
} >"$(fixture multibyte-comment-bypass.json)"
expect_refuse 'the multi-byte padded bypass with a comment' "$(fixture multibyte-comment-bypass.json)"

printf '{"sdk":{"version":"10.0.100"},"note":"caf\303\251"}\n' >"$(fixture one-utf8-char.json)"
expect_refuse 'a single non-ASCII character in a value' "$(fixture one-utf8-char.json)"

printf '{"sdk":{"version":"10.0.100"},"note":"a\377b"}\n' >"$(fixture one-high-byte.json)"
expect_refuse 'a single 0xFF byte in a value' "$(fixture one-high-byte.json)"

printf '{"sdk":{"version":"10.0.100"},"note":"a\000b"}\n' >"$(fixture nul-byte.json)"
expect_refuse 'a NUL byte' "$(fixture nul-byte.json)"

printf '{"sdk":{"version":"10.0.100"},"note":"a\001b"}\n' >"$(fixture control-byte.json)"
expect_refuse 'a control byte' "$(fixture control-byte.json)"

printf '{"sdk":{"version":"10.0.100"},"note":"a\177b"}\n' >"$(fixture del-byte.json)"
expect_refuse 'a DEL byte' "$(fixture del-byte.json)"

# ---- the caller's locale survives the call ----
for locale in C C.UTF-8; do
  TOTAL=$((TOTAL + 1))
  seen="$(LC_ALL="$locale" bash -c 'set -euo pipefail; REPO_DIR=/nonexistent; source "$1"; global_json_safe "$2" || true; printf "%s" "${LC_ALL}"' \
    guard "$LIB" "$(fixture paths.json)" 2>/dev/null)"
  [[ "$seen" == "$locale" ]] || die "the caller's LC_ALL (${locale}) was not restored; saw '${seen}'"
  PASSED=$((PASSED + 1))
done

printf '%s/%s global.json guard assertions passed.\n' "$PASSED" "$TOTAL"
