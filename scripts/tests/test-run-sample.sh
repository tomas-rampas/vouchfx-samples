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
  cp "$SCRIPT_DIR/../dotnet-images.properties" "$ROOT/scripts/dotnet-images.properties"
  cp "$SCRIPT_DIR/../run-migrations.sh" "$ROOT/scripts/run-migrations.sh"
  export VOUCHFX_SAMPLES_TEST_LOG="$ROOT/calls.log"
  export VOUCHFX_SAMPLES_TEST_EXPECT_FIXTURE=''
  export VOUCHFX_SAMPLES_TEST_DOCKER_EXIT=0
  export VOUCHFX_SAMPLES_TEST_RUNNER_BUILD_EXIT=0
  export VOUCHFX_SAMPLES_TEST_CLI_EXIT=0
  export VOUCHFX_SAMPLES_TEST_VERSION='1.0.0-sample-test+not-released'
  export VOUCHFX_SAMPLES_TEST_VERSION_EXIT=0
  unset VOUCHFX_SAMPLES_CLI VOUCHFX_SAMPLES_CLI_VERSION
  unset VOUCHFX_SAMPLE_DOTNET_SDK_IMAGE VOUCHFX_SAMPLE_DOTNET_RUNTIME_IMAGE
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

new_case 'source Compose variant discovery'
sample orders-dotnet app
sample orders-dotnet-compose
run_case 0 all; count_is 3
line_is 1 'docker build *orders-dotnet:local*'
line_is 2 'dotnet run *orders-dotnet/tests*'
line_is 3 'dotnet run *orders-dotnet-compose/tests*'
pass

new_case 'installed Compose variant selection' installed
sample orders-dotnet-compose
run_case 0 orders-dotnet-compose; count_is 2
line_is 1 'cli --version'
line_is 2 'cli run *orders-dotnet-compose/tests*--fail-on-env-error*--fail-on-inconclusive*'
[[ ! -d "$ROOT/.vouchfx-src" ]] || fail 'Compose candidate mode created a source checkout.'
pass

new_case 'default image build passes no image overrides'
sample app app
run_case 0 app; count_is 2
line_is 1 'docker build -t *'
pass

new_case 'image overrides reach docker build'
sample app app
export VOUCHFX_SAMPLE_DOTNET_SDK_IMAGE='registry.example.invalid/dotnet/sdk:override'
export VOUCHFX_SAMPLE_DOTNET_RUNTIME_IMAGE='registry.example.invalid/dotnet/aspnet:override'
run_case 0 app; count_is 2
line_is 1 'docker build --build-arg DOTNET_SDK_IMAGE=registry.example.invalid/dotnet/sdk:override --build-arg DOTNET_RUNTIME_IMAGE=registry.example.invalid/dotnet/aspnet:override -t *'
pass

new_case 'single image override leaves the other default'
sample app app
export VOUCHFX_SAMPLE_DOTNET_RUNTIME_IMAGE='registry.example.invalid/dotnet/aspnet:override'
run_case 0 app; count_is 2
line_is 1 'docker build --build-arg DOTNET_RUNTIME_IMAGE=registry.example.invalid/dotnet/aspnet:override -t *'
pass

new_case 'sdk-only image override leaves the runtime default'
sample app app
export VOUCHFX_SAMPLE_DOTNET_SDK_IMAGE='registry.example.invalid/dotnet/sdk:override'
run_case 0 app; count_is 2
line_is 1 'docker build --build-arg DOTNET_SDK_IMAGE=registry.example.invalid/dotnet/sdk:override -t *'
[[ "$(sed -n 1p "$VOUCHFX_SAMPLES_TEST_LOG")" != *DOTNET_RUNTIME_IMAGE=* ]] || fail 'An SDK-only override also set DOTNET_RUNTIME_IMAGE.'
grep -qF 'VOUCHFX_SAMPLE_DOTNET_SDK_IMAGE is set: the application build uses registry.example.invalid/dotnet/sdk:override' "$ROOT/console.log" || fail 'The effective image override was not logged.'
grep -qF 'WARNING: VOUCHFX_SAMPLE_DOTNET_SDK_IMAGE is not pinned by digest' "$ROOT/console.log" || fail 'A tag-only override did not warn.'
pass

new_case 'digest-pinned image override does not warn'
sample app app
export VOUCHFX_SAMPLE_DOTNET_RUNTIME_IMAGE='registry.example.invalid/dotnet/aspnet:10.0@sha256:0000000000000000000000000000000000000000000000000000000000000000'
run_case 0 app; count_is 2
if grep -q 'WARNING' "$ROOT/console.log"; then fail 'A digest-pinned override warned.'; fi
pass

new_case 'image override with a space is refused before docker'
sample app app
export VOUCHFX_SAMPLE_DOTNET_SDK_IMAGE='registry.example.invalid/dotnet/sdk:override --output=/tmp/x'
run_case 1 app; count_is 0
grep -qF 'VOUCHFX_SAMPLE_DOTNET_SDK_IMAGE must not contain whitespace or control characters' "$ROOT/console.log" || fail 'The refusal did not name the variable.'
pass

new_case 'image override with an embedded newline is refused before docker'
sample app app
export VOUCHFX_SAMPLE_DOTNET_RUNTIME_IMAGE=$'registry.example.invalid/dotnet/aspnet:override\n--output=/tmp/x'
run_case 1 app; count_is 0
grep -qF 'VOUCHFX_SAMPLE_DOTNET_RUNTIME_IMAGE must not contain whitespace or control characters' "$ROOT/console.log" || fail 'The refusal did not name the variable.'
pass

new_case 'migration image override with a space or newline is refused before docker'
mkdir -p "$ROOT/samples/orders-dotnet/app"
for name in from-postman from-xunit from-specflow; do
  mkdir -p "$ROOT/migrations/$name/ported"
done
for bad in 'registry.example.invalid/dotnet/sdk:override --output=/tmp/x' $'registry.example.invalid/dotnet/sdk:override\n--output=/tmp/x'; do
  export VOUCHFX_SAMPLE_DOTNET_SDK_IMAGE="$bad"
  rc=0
  bash "$ROOT/scripts/run-migrations.sh" > "$ROOT/console.log" 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]] || fail "Migration runner returned $rc for a refused override."
  count_is 0
  grep -qF 'VOUCHFX_SAMPLE_DOTNET_SDK_IMAGE must not contain whitespace or control characters' "$ROOT/console.log" || fail 'The migration refusal did not name the variable.'
done
pass

new_case 'dockerfile and compose defaults match the pinned .NET 10 images'
# shellcheck source=scripts/dotnet-images.properties
source "$SCRIPT_DIR/../dotnet-images.properties"
sample_root="$SCRIPT_DIR/../../samples"
grep -qxF "ARG DOTNET_SDK_IMAGE=$sdk_10_0" "$sample_root/orders-dotnet/app/Dockerfile" || fail 'Dockerfile SDK default differs from the pinned .NET 10 image.'
grep -qxF "ARG DOTNET_RUNTIME_IMAGE=$runtime_10_0" "$sample_root/orders-dotnet/app/Dockerfile" || fail 'Dockerfile runtime default differs from the pinned .NET 10 image.'
grep -qF "VOUCHFX_SAMPLE_DOTNET_SDK_IMAGE:-$sdk_10_0}" "$sample_root/orders-dotnet-compose/compose.yaml" || fail 'Compose SDK default differs from the pinned .NET 10 image.'
grep -qF "VOUCHFX_SAMPLE_DOTNET_RUNTIME_IMAGE:-$runtime_10_0}" "$sample_root/orders-dotnet-compose/compose.yaml" || fail 'Compose runtime default differs from the pinned .NET 10 image.'
[[ "$sdk_10_0" =~ ^mcr\.microsoft\.com/dotnet/sdk:10\.0@sha256:[a-f0-9]{64}$ ]] || fail 'The pinned SDK image is not an immutable digest reference.'
[[ "$runtime_10_0" =~ ^mcr\.microsoft\.com/dotnet/aspnet:10\.0@sha256:[a-f0-9]{64}$ ]] || fail 'The pinned runtime image is not an immutable digest reference.'
[[ "$(grep -c '=' "$SCRIPT_DIR/../dotnet-images.properties")" -eq 2 ]] || fail 'The pin file must hold only the .NET 10 pair.'
pass

new_case 'migration image overrides'
export VOUCHFX_SAMPLE_DOTNET_SDK_IMAGE='registry.example.invalid/dotnet/sdk:override'
export VOUCHFX_SAMPLE_DOTNET_RUNTIME_IMAGE='registry.example.invalid/dotnet/aspnet:override'
mkdir -p "$ROOT/samples/orders-dotnet/app"
for name in from-postman from-xunit from-specflow; do
  mkdir -p "$ROOT/migrations/$name/ported"
done
rc=0
bash "$ROOT/scripts/run-migrations.sh" > "$ROOT/console.log" 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] || fail "Migration runner returned $rc."
count_is 4
line_is 1 'docker build --build-arg DOTNET_SDK_IMAGE=registry.example.invalid/dotnet/sdk:override --build-arg DOTNET_RUNTIME_IMAGE=registry.example.invalid/dotnet/aspnet:override -t *'
line_is 2 'dotnet run *--fail-on-env-error*--fail-on-inconclusive*'
line_is 3 'dotnet run *--fail-on-env-error*--fail-on-inconclusive*'
line_is 4 'dotnet run *--fail-on-env-error*--fail-on-inconclusive*'
pass

new_case 'bootstrap preserves pin and enables runtime roll forward'
cp "$SCRIPT_DIR/../bootstrap.sh" "$ROOT/scripts/bootstrap.sh"
git -C "$ROOT/.vouchfx-src" init -q
git -C "$ROOT/.vouchfx-src" add .
git -C "$ROOT/.vouchfx-src" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture
git -C "$ROOT/.vouchfx-src" rev-parse HEAD > "$ROOT/ENGINE_PIN"
rc=0
bash "$ROOT/scripts/bootstrap.sh" > "$ROOT/console.log" 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] || fail "Bootstrap returned $rc."
count_is 3
line_is 3 'dotnet build *-c Release -p:RollForward=Major'
[[ -z "$(git -C "$ROOT/.vouchfx-src" status --porcelain)" ]] || fail 'Bootstrap changed the pinned source.'
pass

printf '%s/26 Bash sample-runner regressions passed.\n' "$PASSED"
