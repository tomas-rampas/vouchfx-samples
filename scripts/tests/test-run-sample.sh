#!/usr/bin/env bash
# Docker-free native subprocess regressions for scripts/run-sample.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="${SCRIPT_DIR}/../run-sample.sh"
TEMP_ROOT="$(cd "${TMPDIR:-/tmp}" && pwd)"
SCRATCH="$(mktemp -d "${TEMP_ROOT}/vouchfx-sample-tests.XXXXXX")"
BIN="${SCRATCH}/native stubs"
PASSED=0

cleanup() {
  case "$SCRATCH" in
    "${TEMP_ROOT}"/vouchfx-sample-tests.*) rm -rf "$SCRATCH" ;;
    *) printf 'Refusing to remove unexpected scratch path: %s\n' "$SCRATCH" >&2; exit 1 ;;
  esac
}
trap cleanup EXIT
mkdir -p "$BIN"

cat > "$BIN/docker" <<'STUB'
#!/bin/sh
printf '%s\n' "docker $*" >> "$VOUCHFX_SAMPLES_TEST_LOG"
printf '%s\n' 'docker native output'
if [ -n "$VOUCHFX_SAMPLES_TEST_EXPECT_FIXTURE" ] && [ ! -f "$VOUCHFX_SAMPLES_TEST_EXPECT_FIXTURE" ]; then exit 91; fi
exit "$VOUCHFX_SAMPLES_TEST_DOCKER_EXIT"
STUB
cat > "$BIN/dotnet" <<'STUB'
#!/bin/sh
printf '%s\n' "dotnet $*" >> "$VOUCHFX_SAMPLES_TEST_LOG"
printf '%s\n' 'dotnet native output'
if [ "$1" = build ]; then exit "$VOUCHFX_SAMPLES_TEST_RUNNER_BUILD_EXIT"; fi
exit "$VOUCHFX_SAMPLES_TEST_CLI_EXIT"
STUB
cat > "$BIN/candidate cli" <<'STUB'
#!/bin/sh
printf '%s\n' "cli $*" >> "$VOUCHFX_SAMPLES_TEST_LOG"
if [ "$1" = --version ]; then printf '%s\n' "$VOUCHFX_SAMPLES_TEST_VERSION"; exit "$VOUCHFX_SAMPLES_TEST_VERSION_EXIT"; fi
printf '%s\n' 'cli native output'
if [ -n "$VOUCHFX_SAMPLES_TEST_EXPECT_FIXTURE" ] && [ ! -f "$VOUCHFX_SAMPLES_TEST_EXPECT_FIXTURE" ]; then exit 91; fi
exit "$VOUCHFX_SAMPLES_TEST_CLI_EXIT"
STUB
chmod +x "$BIN/docker" "$BIN/dotnet" "$BIN/candidate cli"
export PATH="${BIN}:${PATH}"

new_case() {
  ROOT="${SCRATCH}/$1"
  mkdir -p "$ROOT/scripts"
  cp "$SOURCE" "$ROOT/scripts/run-sample.sh"
  export VOUCHFX_SAMPLES_TEST_LOG="$ROOT/calls.log"
  export VOUCHFX_SAMPLES_TEST_EXPECT_FIXTURE=''
  export VOUCHFX_SAMPLES_TEST_DOCKER_EXIT=0
  export VOUCHFX_SAMPLES_TEST_RUNNER_BUILD_EXIT=0
  export VOUCHFX_SAMPLES_TEST_CLI_EXIT=0
  export VOUCHFX_SAMPLES_TEST_VERSION='1.0.0-sample-test+not-released'
  export VOUCHFX_SAMPLES_TEST_VERSION_EXIT=0
  unset VOUCHFX_SAMPLES_CLI VOUCHFX_SAMPLES_CLI_VERSION
  cat > "$ROOT/scripts/bootstrap.sh" <<'STUB'
#!/bin/sh
printf '%s\n' bootstrap >> "$VOUCHFX_SAMPLES_TEST_LOG"
exit 89
STUB
  chmod +x "$ROOT/scripts/bootstrap.sh"
  if [[ "${2:-source}" == installed ]]; then
    export VOUCHFX_SAMPLES_CLI="$BIN/candidate cli"
    export VOUCHFX_SAMPLES_CLI_VERSION="$VOUCHFX_SAMPLES_TEST_VERSION"
  else
    mkdir -p "$ROOT/.vouchfx-src/src/Cli/Vouchfx.Cli"
    printf '<Project />\n' > "$ROOT/.vouchfx-src/src/Cli/Vouchfx.Cli/Vouchfx.Cli.csproj"
    printf '# Isolated source fixture\n' > "$ROOT/ENGINE_PIN"
  fi
}

sample() {
  mkdir -p "$ROOT/samples/$1/tests"
  case "${2:-dependency}" in
    app) mkdir -p "$ROOT/samples/$1/app" ;;
    custom) mkdir -p "$ROOT/samples/$1/runner"; printf '<Project />\n' > "$ROOT/samples/$1/runner/Test.csproj" ;;
  esac
}

setup() {
  cat > "$ROOT/samples/$1/setup.sh" <<'STUB'
#!/bin/sh
sample_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
printf '%s\n' "setup $(basename "$sample_dir")" >> "$VOUCHFX_SAMPLES_TEST_LOG"
printf '%s\n' 'setup output'
printf fixture > "$sample_dir/tests/generated.txt"
exit 0
STUB
}

fail() {
  printf '%s\n' "$1" >&2
  [[ ! -f "$ROOT/console.log" ]] || cat "$ROOT/console.log" >&2
  exit 1
}

run_case() {
  local expected="$1" target="$2" rc=0
  bash "$ROOT/scripts/run-sample.sh" "$target" > "$ROOT/console.log" 2>&1 || rc=$?
  [[ "$rc" -eq "$expected" ]] || fail "Expected exit $expected, got $rc."
}

count_is() {
  local actual=0
  if [[ -f "$VOUCHFX_SAMPLES_TEST_LOG" ]]; then
    actual="$(wc -l < "$VOUCHFX_SAMPLES_TEST_LOG" | tr -d '[:space:]')"
  fi
  [[ "$actual" -eq "$1" ]] || fail "Expected $1 native/setup calls, got $actual."
}

line_is() {
  local actual
  actual="$(sed -n "${1}p" "$VOUCHFX_SAMPLES_TEST_LOG")"
  # The second argument is an intentional glob for paths/arguments.
  # shellcheck disable=SC2053
  [[ "$actual" == $2 ]] || fail "Unexpected call $1: $actual."
}

pass() { PASSED=$((PASSED + 1)); }

new_case 'source dependency'
sample dependency
setup dependency
export VOUCHFX_SAMPLES_TEST_EXPECT_FIXTURE="$ROOT/samples/dependency/tests/generated.txt"
run_case 0 dependency; count_is 2; line_is 1 'setup dependency'; line_is 2 'dotnet run *'; pass

new_case 'source image ordering'
sample app app; setup app
export VOUCHFX_SAMPLES_TEST_EXPECT_FIXTURE="$ROOT/samples/app/tests/generated.txt"
run_case 0 app; count_is 3; line_is 1 'setup app'; line_is 2 'docker build *'; line_is 3 'dotnet run *'; pass

new_case 'source image failure'
sample app app
export VOUCHFX_SAMPLES_TEST_DOCKER_EXIT=23
run_case 1 app; count_is 1; line_is 1 'docker build *'; pass

new_case 'source custom runner'
sample custom custom
run_case 0 custom; count_is 2; line_is 1 'dotnet build *'; line_is 2 'dotnet run *'; pass

new_case 'installed dependency' installed
sample dependency; setup dependency
export VOUCHFX_SAMPLES_TEST_EXPECT_FIXTURE="$ROOT/samples/dependency/tests/generated.txt"
run_case 0 dependency; count_is 3; line_is 1 'cli --version'; line_is 2 'setup dependency'
line_is 3 'cli run *--fail-on-env-error*--fail-on-inconclusive*'
[[ ! -d "$ROOT/.vouchfx-src" ]] || fail 'Installed mode created a source checkout.'
pass

new_case 'installed image ordering' installed
sample app app; setup app
run_case 0 app; count_is 4; line_is 1 'cli --version'; line_is 2 'setup app'; line_is 3 'docker build *'; line_is 4 'cli run *'; pass

new_case 'installed version mismatch' installed
sample app app; setup app
export VOUCHFX_SAMPLES_TEST_VERSION='1.0.0-wrong-build'
run_case 1 all; count_is 1; line_is 1 'cli --version'; pass

new_case 'installed version failure' installed
sample app app
export VOUCHFX_SAMPLES_TEST_VERSION_EXIT=9
run_case 1 all; count_is 1; pass

new_case 'installed missing expected version' installed
sample app app
unset VOUCHFX_SAMPLES_CLI_VERSION
run_case 1 app; count_is 0; pass

new_case 'installed missing executable setting' installed
sample app app
unset VOUCHFX_SAMPLES_CLI
run_case 1 app; count_is 0; pass

new_case 'installed missing executable file' installed
sample app app
export VOUCHFX_SAMPLES_CLI="$ROOT/missing executable"
run_case 1 app; count_is 0; pass

new_case 'installed CLI environment failure' installed
sample dependency
export VOUCHFX_SAMPLES_TEST_CLI_EXIT=3
run_case 3 all; count_is 2; line_is 2 'cli run *'; pass

new_case 'installed custom runner refusal' installed
sample a-custom custom; setup a-custom
sample b-standard
run_case 1 all; count_is 2; line_is 2 'cli run *b-standard*'
grep -q 'Unset VOUCHFX_SAMPLES_CLI' "$ROOT/console.log" || fail 'Missing actionable refusal.'
grep -q 'a-custom: exit 1' "$ROOT/console.log" || fail 'Missing custom-runner summary.'
grep -q 'b-standard: exit 0' "$ROOT/console.log" || fail 'Missing standard-sample summary.'
pass

printf '%s/13 Bash sample-runner regressions passed.\n' "$PASSED"
