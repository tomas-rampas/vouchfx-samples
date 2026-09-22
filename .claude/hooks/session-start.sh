#!/usr/bin/env bash
# .claude/hooks/session-start.sh: SessionStart bootstrap for Claude Code on the web.
#
# Registered in .claude/settings.json. It runs only in a Claude Code on the web
# container ($CLAUDE_CODE_REMOTE=true); a local machine keeps whatever SDK its owner
# installed and is never touched.
#
# What it guarantees, idempotently:
#   1. A .NET 8 SDK that satisfies global.json (8.0.400, rollForward latestFeature).
#      The web sandbox's egress proxy blocks builds.dotnet.microsoft.com (where
#      dotnet-install.sh downloads from), and Ubuntu 24.04's own dotnet-sdk-8.0 is an
#      8.0.1xx build, below global.json's floor. Microsoft's Ubuntu 22.04 (jammy) apt
#      feed carries the 8.0.4xx band and installs cleanly on noble, so that is the
#      source used. An apt preference pins every dotnet package to that feed, so apt
#      never mixes Ubuntu's own host/runtime packages into the Microsoft SDK.
#   2. /usr/bin/dotnet, and DOTNET_ROOT/PATH in /etc/profile.d/dotnet.sh and in
#      $CLAUDE_ENV_FILE, so login shells and the session's own tool calls agree.
#   3. The published `vouchfx` global tool for the engine commit ENGINE_PIN names, for
#      `vouchfx validate`/`list` while authoring samples. (Running a sample still goes
#      through scripts/bootstrap.sh's source build, which needs Docker.) ENGINE_PIN pins
#      a bare commit SHA, so the version is found by asking the engine repository which
#      release tag points at that commit (`git ls-remote`). A pin that is not a tagged
#      release commit installs nothing and says so. The tool is installed only into an
#      EMPTY slot and never replaces a different installed version: when several fleet
#      repos share one session, vouchfx-mcp's hook owns the global tool, because its
#      parity tests gate on an exact version and would otherwise silently skip.
#
# Synchronous by design: the session starts only once the SDK is present, so nothing
# races a half-installed toolchain. On a container that already has the SDK (the web
# environment caches container state after this hook completes) it finishes in well
# under a second. Progress goes to stderr; the single summary line on stdout is what
# the session sees.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

DOTNET_DIR=/usr/share/dotnet
MS_KEYRING=/usr/share/keyrings/microsoft-prod.gpg
MS_LIST=/etc/apt/sources.list.d/microsoft-prod.list
MS_PREFS=/etc/apt/preferences.d/dotnet-microsoft

log() { printf '[session-start] %s\n' "$*" >&2; }
REPO_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

VOUCHFX_TOOL="${DOTNET_CLI_HOME:-$HOME}/.dotnet/tools/vouchfx"

# Installs the vouchfx global tool at exactly $1 (a NuGet version, no leading "v").
# nuget.org is ADDED as a source, never replacing configured ones, as the CI install
# step does. A different installed version is uninstalled first, because
# `dotnet tool update` refuses to move to a lower version.
install_cli() {
  local want="$1" have
  have="$(dotnet tool list -g 2>/dev/null | awk 'tolower($1)=="vouchfx" {print $2}')"
  [ "$have" = "$want" ] && return 0
  if [ -n "$have" ]; then
    log "Replacing vouchfx ${have} with ${want}."
    dotnet tool uninstall -g vouchfx >/dev/null
  else
    log "Installing vouchfx ${want}."
  fi
  dotnet tool install -g vouchfx --version "$want" --add-source https://api.nuget.org/v3/index.json >/dev/null
}

# The installed CLI's informational version ("<version>+<commit-sha>"), or empty.
cli_version() { "$VOUCHFX_TOOL" --version 2>/dev/null | head -n1 | tr -d '\r' || true; }

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    log "ERROR: installing the .NET SDK needs root, and sudo is not available."
    exit 1
  fi
}

# True when an SDK in the 8.0.4xx band or later is installed. Captured before grep so
# `grep -q` exiting early cannot SIGPIPE `dotnet` into a pipefail.
sdk_ok() {
  local sdks
  sdks="$("$DOTNET_DIR/dotnet" --list-sdks 2>/dev/null || true)"
  grep -Eq '^8\.0\.[4-9][0-9]{2} ' <<<"$sdks"
}

install_sdk() {
  export DEBIAN_FRONTEND=noninteractive
  local arch line
  arch="$(dpkg --print-architecture)"
  line="deb [arch=${arch} signed-by=${MS_KEYRING}] https://packages.microsoft.com/ubuntu/22.04/prod jammy main"

  if [ ! -s "$MS_KEYRING" ]; then
    log "Adding Microsoft's package signing key."
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | as_root gpg --dearmor --yes -o "$MS_KEYRING"
  fi
  if [ "$(cat "$MS_LIST" 2>/dev/null)" != "$line" ]; then
    printf '%s\n' "$line" | as_root tee "$MS_LIST" >/dev/null
  fi
  printf 'Package: dotnet* aspnetcore* netstandard*\nPin: origin "packages.microsoft.com"\nPin-Priority: 1001\n' \
    | as_root tee "$MS_PREFS" >/dev/null

  # Refresh only the Microsoft list (seconds), keeping the image's other lists as they
  # are; fall back to a full refresh if a dependency then cannot be resolved.
  log "Installing dotnet-sdk-8.0 from Microsoft's jammy feed."
  as_root apt-get update -qq -o Dir::Etc::sourcelist=sources.list.d/microsoft-prod.list \
    -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0
  if ! as_root apt-get install -y -qq dotnet-sdk-8.0 >/dev/null; then
    log "Retrying after a full apt refresh."
    as_root apt-get update -qq
    as_root apt-get install -y -qq dotnet-sdk-8.0 >/dev/null
  fi
}

write_profile() {
  local profile=/etc/profile.d/dotnet.sh want
  want='# Written by .claude/hooks/session-start.sh (Claude Code on the web).
export DOTNET_ROOT=/usr/share/dotnet
case ":$PATH:" in *":/usr/share/dotnet:"*) ;; *) PATH="/usr/share/dotnet:$PATH" ;; esac
case ":$PATH:" in *":$HOME/.dotnet/tools:"*) ;; *) PATH="$PATH:$HOME/.dotnet/tools" ;; esac
export PATH
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1'
  if [ "$(cat "$profile" 2>/dev/null)" != "$want" ]; then
    printf '%s\n' "$want" | as_root tee "$profile" >/dev/null
  fi
  if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    printf '%s\n' "$want" >>"$CLAUDE_ENV_FILE"
  fi
}

if ! sdk_ok; then
  install_sdk
  sdk_ok || { log "ERROR: dotnet-sdk-8.0 installed, but no 8.0.4xx SDK is visible under ${DOTNET_DIR}."; exit 1; }
fi
[ "$(readlink -f /usr/bin/dotnet 2>/dev/null)" = "$DOTNET_DIR/dotnet" ] || as_root ln -sf "$DOTNET_DIR/dotnet" /usr/bin/dotnet
write_profile

export DOTNET_ROOT="$DOTNET_DIR" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
# ---- the engine CLI, for the pinned commit ----
summary_cli="vouchfx not installed (see stderr)"
pin_sha="$(head -n1 "$REPO_DIR/ENGINE_PIN" | tr -d '[:space:]')"
if [[ "$pin_sha" =~ ^[0-9a-f]{40}$ ]]; then
  actual="$(cli_version)"
  if [ -z "$actual" ]; then
    # Exact release tags only (never the floating v1-rc tag); an annotated tag's commit
    # is the peeled "^{}" line.
    tag="$(git ls-remote --tags https://github.com/tomas-rampas/vouchfx.git 'refs/tags/v*' 2>/dev/null \
      | awk -v sha="$pin_sha" '$1 == sha { t = $2; sub(/^refs\/tags\//, "", t); sub(/\^\{\}$/, "", t); print t }' \
      | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' | head -n1 || true)"
    if [ -n "$tag" ]; then
      install_cli "${tag#v}" || log "WARNING: could not install vouchfx ${tag#v}."
      actual="$(cli_version)"
    else
      log "NOTE: ENGINE_PIN ${pin_sha:0:12} is not a tagged engine release; no published CLI matches it."
    fi
  fi
  case "$actual" in
    *"+${pin_sha}") summary_cli="vouchfx ${actual} matches ENGINE_PIN" ;;
    "") ;;
    *) summary_cli="vouchfx ${actual} is installed; ENGINE_PIN is ${pin_sha:0:12} (left as is, see this hook's header)" ;;
  esac
else
  log "WARNING: ENGINE_PIN's first line is not a 40-character commit SHA; skipping the CLI install."
fi
echo "session-start: .NET SDK $("$DOTNET_DIR/dotnet" --version) ready; ${summary_cli}."
