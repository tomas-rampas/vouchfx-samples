#!/usr/bin/env bash
# .claude/hooks/session-start.sh: SessionStart bootstrap for Claude Code on the web.
#
# Registered in .claude/settings.json. It runs only in a Claude Code on the web
# container ($CLAUDE_CODE_REMOTE=true); a local machine keeps whatever SDK its owner
# installed and is never touched.
#
# What it guarantees, idempotently:
#   1. A .NET 10 SDK that satisfies this repository's global.json.
#      The web sandbox's egress proxy blocks builds.dotnet.microsoft.com (where
#      dotnet-install.sh downloads from), and Microsoft's Ubuntu 22.04 (jammy) apt feed,
#      which this hook used for .NET 8, publishes no dotnet-sdk-10.0. Ubuntu 24.04's own
#      archive (noble-updates/noble-security) carries dotnet-sdk-10.0 in the 10.0.1xx
#      band, which satisfies global.json, so that is the source used. It installs under
#      /usr/lib/dotnet.
#      A container in which the .NET 8 version of this hook ran carries Microsoft-feed
#      .NET packages (SDK, runtimes, dotnet-host, hostfxr, targeting packs), the
#      microsoft-prod apt list and its keyring, and the apt preference
#      /etc/apt/preferences.d/dotnet-microsoft that pinned dotnet packages to that feed.
#      Left in place they make a mixed-vendor install: Ubuntu's dotnet-host-10.0
#      conflicts with Microsoft's dotnet-host, so apt removes the muxer and cross-grades
#      hostfxr, stranding the old SDK and runtimes in /usr/share/dotnet with no host.
#      The list and keyring paths are NOT proof of that hook: Microsoft's own package
#      setup writes the same two files. Only the dotnet-microsoft preference is this hook
#      family's footprint. So, whenever it runs as root and that preference exists, the
#      hook deletes it together with the Microsoft list and keyring; without it, the
#      list and keyring are left alone. It then purges every installed
#      dotnet*/aspnetcore*/netstandard* package whose version is not an Ubuntu build, but
#      only when that footprint is present: the dotnet-microsoft preference existed when
#      this run started, or a non-Ubuntu dotnet-host (the package that conflicts) is
#      installed. Otherwise non-Ubuntu .NET
#      packages, which someone may have installed on purpose, are not purged (installing the
#      SDK can still move any of its own dependencies to the Ubuntu build). The purge
#      is simulated first: if the simulation fails, or prints any action other than a
#      purge of exactly those packages, the hook stops and purges nothing. A fresh
#      container skips that step. Also whenever it runs as root, it (re)writes an apt
#      preference that pins those packages to Ubuntu's <codename>-updates and
#      <codename>-security suites only, replacing any wider pin an earlier version wrote;
#      a missing or malformed VERSION_CODENAME stops the hook before the pin is written.
#      The install runs with --no-remove, so it fails rather than removing any package.
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
#      It owns it by replacing any other version it finds, so the order the hooks
#      run in does not matter: measured both ways, the slot ends at vouchfx-mcp's
#      pin whether this hook ran first (vouchfx-mcp's then replaced what it installed)
#      or second (it left vouchfx-mcp's install alone).
#      It is installed with --allow-roll-forward: a published tool built for an earlier
#      runtime must still start on a host that carries only .NET 10. The version probe runs
#      the tool as installed first; only if that fails does it retry with
#      DOTNET_ROLL_FORWARD=Major for that one probe (never exported), and the summary then
#      says the tool "runs only with DOTNET_ROLL_FORWARD=Major".
#
# global.json guard. The .NET 10 host honours "sdk.paths" in global.json, which names
# directories the host loads an SDK (and its native host policy library) from. Running
# `dotnet` inside the repository as root would then run whatever a branch put there. So
# before any dotnet call the hook refuses, failing closed, a global.json whose "sdk"
# object holds anything but "version", "rollForward" and "allowPrerelease", or that it
# cannot classify. Every other dotnet call (tool list, tool install, the summary
# version) runs from a scratch directory outside the repository.
#
# Synchronous by design: the session starts only once the SDK is present, so nothing
# races a half-installed toolchain. On a container that already has the SDK (the web
# environment caches container state after this hook completes) it finishes in well
# under a second. Progress goes to stderr; the single summary line on stdout is what
# the session sees, so it also reports how many packages a purge removed.
#
# Trust model. This file comes from the checked-out branch, and the SessionStart hook
# runs it at session start (as root in a web container) before anyone has read the
# diff. So .claude/ is treated like .github/workflows/: it is code-owned in
# .github/CODEOWNERS, and web sessions should be opened only on branches you trust.
# The alternative is to move this bootstrap into the Claude Code environment's own
# setup script, which no branch controls, and delete this file and its registration:
# remove the SessionStart registration from .claude/settings.json. That file holds only
# the "hooks" block today, so check it still does before deleting the whole file.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

DOTNET_DIR=/usr/lib/dotnet
DOTNET_PREFS=/etc/apt/preferences.d/dotnet-ubuntu
# Left by the .NET 8 version of this hook: Microsoft's jammy feed, its signing key, and
# the preference that pinned dotnet packages to it. Microsoft's own setup also writes the
# list and keyring paths, so only LEGACY_MS_PREFS (written by this hook family alone)
# counts as evidence that this hook put the other two there.
LEGACY_MS_LIST=/etc/apt/sources.list.d/microsoft-prod.list
LEGACY_MS_KEYRING=/usr/share/keyrings/microsoft-prod.gpg
LEGACY_MS_PREFS=/etc/apt/preferences.d/dotnet-microsoft
# Set by remove_microsoft_feed to the number of packages it purged, for the summary line.
PURGED_COUNT=0

log() { printf '[session-start] %s\n' "$*" >&2; }
REPO_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

VOUCHFX_TOOL="${DOTNET_CLI_HOME:-$HOME}/.dotnet/tools/vouchfx"

# A NuGet config that holds nuget.org and nothing else, for the one install below.
# `dotnet tool install` is given --configfile with this <clear/> config, so nuget.org is
# the only source. --add-source would only ADD nuget.org beside every feed already
# configured (machine, user, and any nuget.config above the working directory), any of
# which could serve a same-version `vouchfx`. Measured on SDK 8.0.425: a fake 1.0.0-rc.5 packed into a folder feed that a local nuget.config named was
# installed instead of nuget.org's under --add-source, and nuget.org's was installed under
# --configfile with this file. The version check after the install proves only the commit
# a package claims, so it cannot stand in for choosing the source.
nuget_org_only_config() {
  local dir
  # Callers use this inside `||` lists, where `set -e` is off, so a failed mktemp must
  # return explicitly instead of writing into an empty path.
  dir="$(mktemp -d)" || return 1
  printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>' '<configuration>' '  <packageSources>' \
    '    <clear />' '    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />' \
    '  </packageSources>' '</configuration>' >"$dir/nuget.config"
  # An empty global.json stops the host's walk up to /tmp/global.json or /global.json.
  printf '{}\n' >"$dir/global.json"
  printf '%s' "$dir"
}

# Installs the vouchfx global tool at exactly $1 (a NuGet version, no leading "v"), but
# only into an EMPTY slot. When any vouchfx is already registered it is left untouched,
# whatever its version and even when its shim cannot answer --version: that slot belongs
# to whichever repo installed it (see the header), and removing it here could take away
# the exact version another repo's tests gate on. The package comes from nuget.org alone
# (nuget_org_only_config, above).
# dotnet is called by absolute path: a non-root run never links /usr/bin/dotnet, and
# the PATH this hook writes only reaches later processes, not this one.
install_cli() {
  local want="$1" listing have cfg status=0
  # Both dotnet calls below run from the scratch directory that holds the NuGet config,
  # never from the repository: the host reads global.json from the working directory.
  cfg="$(nuget_org_only_config)" || {
    log "WARNING: could not create a scratch directory, so vouchfx ${want} was not installed."
    return 0
  }
  # A listing that fails says nothing about the slot, and it cannot be treated as empty:
  # `dotnet tool install` over a registered tool UPDATES it (measured on SDK
  # 8.0.425, 1.0.0-rc.4 to 1.0.0-rc.5, exit 0; not re-measured on SDK 10), so installing
  # blind could replace the version another repo installed. Decline instead, and say so.
  if ! listing="$(cd "$cfg" && "$DOTNET_DIR/dotnet" tool list -g 2>/dev/null)"; then
    rm -rf "$cfg"
    log "WARNING: could not list the global tools, so vouchfx ${want} was not installed (this hook never installs into a slot it cannot inspect)."
    return 0
  fi
  have="$(awk 'tolower($1)=="vouchfx" {print $2}' <<<"$listing")"
  if [ -n "$have" ]; then
    rm -rf "$cfg"
    log "vouchfx ${have} is already registered; left as is (this hook never replaces it)."
    return 0
  fi
  log "Installing vouchfx ${want}."
  (cd "$cfg" && "$DOTNET_DIR/dotnet" tool install -g vouchfx --version "$want" --configfile "$cfg/nuget.config" --allow-roll-forward >/dev/null) || status=$?
  rm -rf "$cfg"
  return "$status"
}

# The installed CLI's informational version ("<version>+<commit-sha>"), or empty. Probed
# exactly as installed first; a tool another hook installed without --allow-roll-forward
# fails that on a host that only has .NET 10, so a failed probe is retried once with
# DOTNET_ROLL_FORWARD=Major set for that single command (never exported). Use
# cli_runs_plain to tell which of the two answered.
cli_version() {
  local out
  out="$(cd "$SCRATCH_DIR" && "$VOUCHFX_TOOL" --version 2>/dev/null | head -n1 | tr -d '\r' || true)"
  if [ -z "$out" ]; then
    out="$(cd "$SCRATCH_DIR" && DOTNET_ROLL_FORWARD=Major "$VOUCHFX_TOOL" --version 2>/dev/null | head -n1 | tr -d '\r' || true)"
  fi
  printf '%s\n' "$out"
}

# True when the installed CLI starts without DOTNET_ROLL_FORWARD.
cli_runs_plain() { [ -n "$(cd "$SCRATCH_DIR" && "$VOUCHFX_TOOL" --version 2>/dev/null | head -n1 | tr -d '\r' || true)" ]; }

# The system-wide steps (apt, /usr/bin/dotnet, /etc/profile.d) run only as root, which
# is what a Claude Code on the web container is. This hook NEVER escalates: there is no
# sudo, because a checked-in hook that elevated itself would hand any branch a privileged
# path. Not root and no SDK is a loud refusal; not root with an SDK present skips only
# the system-wide writes.
is_root() { [ "$(id -u)" -eq 0 ]; }

# True when an SDK under $DOTNET_DIR resolves this repository's global.json. The dotnet
# host applies the pinned version and its rollForward policy itself, and exits non-zero
# (145) when no installed SDK satisfies them, so this check cannot drift from global.json
# the way a hard-coded version band could.
# On success it also records the resolved version in SDK_VERSION for the summary line.
SDK_VERSION=""
sdk_ok() { SDK_VERSION="$(cd "$REPO_DIR" && "$DOTNET_DIR/dotnet" --version 2>/dev/null)" || { SDK_VERSION=""; return 1; }; }

# Succeeds only when $REPO_DIR/global.json is a file whose "sdk" object holds nothing but
# "version", "rollForward" and "allowPrerelease" (the .NET 10 host also reads "paths" and
# "errorMessage", and "paths" makes it load an SDK from a directory the branch controls).
# Fails closed: a missing file, a second "sdk" string anywhere (any letter case, which
# also catches one inside a comment), a backslash, or an "sdk" body that is not exactly
# a comma-separated list of those three keys with string or boolean values is refused.
# Needs no jq or python: control characters become spaces, then one anchored pattern is
# matched. The cost is that a legitimate but unusual global.json is refused too.
# One plain line on stdout (the session sees it); no file content is echoed.
refusal_notice() {
  echo "global.json refused by the session hook: do not run dotnet in this checkout until it is reviewed"
}

global_json_safe() {
  local file="${1:-$REPO_DIR/global.json}" text body
  local max_bytes=65536
  local item='"(version|rollForward|allowPrerelease)" *: *("[^"\\]*"|true|false)'
  local sdk_re='"sdk" *: *\{([^{}]*)\}'
  local body_re="^ *(${item}( *, *${item})*)? *\$"
  if [ ! -f "$file" ] || [ -L "$file" ]; then
    log "ERROR: ${file} is missing or is not a regular file (a symlink is refused), so the SDK pin cannot be checked; refusing to run dotnet."
    refusal_notice
    return 1
  fi
  # Read at most max_bytes + 1 bytes: a larger file is refused, never read to the end.
  text="$(head -c $((max_bytes + 1)) "$file" | LC_ALL=C tr '\000-\037' ' ')" || return 1
  if [ "${#text}" -gt "$max_bytes" ]; then
    log "ERROR: ${file} is larger than ${max_bytes} bytes; refusing to run dotnet."
    refusal_notice
    return 1
  fi
  if [ "$(grep -oi '"sdk"' <<<"$text" | wc -l)" -ne 1 ] || [[ "$text" == *\\* ]]; then
    log "ERROR: ${file} must contain exactly one \"sdk\" entry and no backslashes; refusing to run dotnet."
    refusal_notice
    return 1
  fi
  if ! [[ "$text" =~ $sdk_re ]]; then
    log "ERROR: the \"sdk\" entry in ${file} is not a plain object; refusing to run dotnet."
    refusal_notice
    return 1
  fi
  body="${BASH_REMATCH[1]}"
  if ! [[ "$body" =~ $body_re ]]; then
    log "ERROR: \"sdk\" in ${file} may hold only version, rollForward and allowPrerelease (not paths or errorMessage); refusing to run dotnet."
    refusal_notice
    return 1
  fi
}

# Installed .NET packages that are not Ubuntu archive builds, one name per line. Every
# Ubuntu build of these source packages carries "ubuntu" in its version
# (10.0.115-0ubuntu1~24.04.1); Microsoft's feed versions do not (8.0.427-1, 9.0.4-1).
foreign_dotnet_packages() {
  dpkg-query -W -f='${Status}\t${Package}\t${Version}\n' 'dotnet*' 'aspnetcore*' 'netstandard*' 2>/dev/null |
    awk -F'\t' '$1 ~ / installed$/ && $3 !~ /ubuntu/ { print $2 }' || true
}

# True when the first argument, without any :arch suffix, names one of the remaining
# arguments, also compared without their :arch suffix. Exact string comparison only.
in_package_set() {
  local want="${1%%:*}" pkg
  shift
  for pkg in "$@"; do
    [ "${pkg%%:*}" = "$want" ] && return 0
  done
  return 1
}

remove_microsoft_feed() {
  local -a foreign refused
  local file sim line verb name legacy_footprint=false
  # The dotnet-microsoft preference is the one file only this hook family writes, so its
  # presence (recorded before it is deleted) is the evidence that gates both the removal
  # of the Microsoft list and keyring (Microsoft's own setup writes those too) and the
  # purge below. They go first, so no apt operation below can see the Microsoft feed or
  # its priority-1001 pin.
  if [ -e "$LEGACY_MS_PREFS" ]; then
    legacy_footprint=true
    for file in "$LEGACY_MS_LIST" "$LEGACY_MS_KEYRING" "$LEGACY_MS_PREFS"; do
      if [ -e "$file" ]; then
        log "Removing ${file}."
        rm -f "$file"
      fi
    done
  fi

  mapfile -t foreign < <(foreign_dotnet_packages)
  if [ "${#foreign[@]}" -eq 0 ]; then
    return 0
  fi
  # Purge only when the earlier hook's footprint is here: its apt preference was present
  # at the start of this run, or a non-Ubuntu dotnet-host is installed (the package
  # that conflicts with Ubuntu's dotnet-host-10.0). Without either, these packages came
  # from somewhere this hook did not touch, and they are left in place.
  if [ "$legacy_footprint" != true ] && ! in_package_set dotnet-host "${foreign[@]}"; then
    log "Leaving ${#foreign[@]} non-Ubuntu .NET package(s) in place: the dotnet-microsoft apt preference was not present and no non-Ubuntu dotnet-host is installed."
    return 0
  fi
  # Purge exactly these, and nothing else. The simulation runs first; if it fails the
  # hook stops and purges nothing. An action line is one that starts with Inst, Remv,
  # Purg or Conf followed by a space or the end of the line. Every action line must be
  # a Purg of a package in the set; any other action, or a Purg of any other package,
  # refuses the purge rather than carrying it out. Lines that do not start with one of
  # those four verbs (headings, "Need to get ...") are not actions.
  sim="$(apt-get purge -s "${foreign[@]}")" || {
    log "ERROR: the simulated purge of ${foreign[*]} failed; nothing was purged."
    exit 1
  }
  refused=()
  while IFS= read -r line; do
    [[ "$line" =~ ^(Inst|Remv|Purg|Conf)( |$) ]] || continue
    read -r verb name _ <<<"$line"
    if [ "$verb" != "Purg" ] || [ -z "${name:-}" ] || ! in_package_set "$name" "${foreign[@]}"; then
      refused+=("$line")
    fi
  done <<<"$sim"
  if [ "${#refused[@]}" -gt 0 ]; then
    log "ERROR: purging the Microsoft-feed .NET packages (${foreign[*]}) would also do: ${refused[*]}. Nothing was purged; remove them yourself."
    exit 1
  fi
  log "Purging Microsoft-feed .NET packages: ${foreign[*]}."
  apt-get purge -y -qq "${foreign[@]}" >/dev/null
  PURGED_COUNT="${#foreign[@]}"
}

# The Ubuntu codename from /etc/os-release; stops the hook when there is none, or when
# it is anything but one plain lower-case word (it is written into the apt preference).
# Callers run it in a command substitution, so its exit only ends that subshell: each
# caller must stop on its failure explicitly.
os_codename() {
  local codename
  codename="$(awk -F= '$1 == "VERSION_CODENAME" { gsub(/"/, "", $2); print $2 }' /etc/os-release 2>/dev/null || true)"
  if [ -z "$codename" ]; then
    log "ERROR: /etc/os-release names no VERSION_CODENAME, so the Ubuntu suites to pin are unknown."
    exit 1
  fi
  if ! [[ "$codename" =~ ^[a-z][a-z0-9]*$ ]]; then
    log "ERROR: VERSION_CODENAME in /etc/os-release is not a single lower-case word, so it is not written into the apt preference."
    exit 1
  fi
  printf '%s\n' "$codename"
}

# Pins dotnet*, aspnetcore* and netstandard* to Ubuntu's <codename>-updates and
# <codename>-security suites. Written whenever the hook runs as root, not only before an
# install, so a container where an earlier version of this hook wrote a wider pin gets
# this one. Rewriting it is idempotent.
write_dotnet_pin() {
  local codename
  codename="$(os_codename)" || exit 1

  # Above 1000 a pin also permits downgrades, so it names only the two suites that publish
  # dotnet-sdk-10.0, not every Ubuntu suite (backports and proposed stay at their defaults).
  printf 'Package: dotnet* aspnetcore* netstandard*\nPin: release o=Ubuntu,a=%s\nPin-Priority: 1001\n\n' \
    "${codename}-updates" "${codename}-security" >"$DOTNET_PREFS"
}

# Reached only as root, after the main block below has written the pin, so it does not
# write the pin again.
install_sdk() {
  export DEBIAN_FRONTEND=noninteractive
  local codename
  codename="$(os_codename)" || exit 1

  # dotnet-sdk-10.0 is published in <codename>-updates and -security, so the image's own
  # Ubuntu lists need a refresh; the package archive is reachable through the proxy.
  log "Installing dotnet-sdk-10.0 from Ubuntu's ${codename}-updates/${codename}-security archive."
  apt-get update -qq
  apt-get install -y -qq --no-remove dotnet-sdk-10.0 >/dev/null
}

write_profile() {
  local profile=/etc/profile.d/dotnet.sh want marker
  # The first line is the CLAUDE_ENV_FILE marker. It names the SDK root, so a block an
  # older version of this hook (or another fleet hook) wrote for a different root, such
  # as /usr/share/dotnet, is not mistaken for this one and this block is still appended.
  marker="# Written by .claude/hooks/session-start.sh (Claude Code on the web); DOTNET_ROOT=${DOTNET_DIR}"
  # The block is written verbatim: $PATH and friends must expand when it is sourced, not now.
  # shellcheck disable=SC2016
  want="${marker}"'
export DOTNET_ROOT=/usr/lib/dotnet
case ":$PATH:" in *":/usr/lib/dotnet:"*) ;; *) PATH="/usr/lib/dotnet:$PATH" ;; esac
case ":$PATH:" in *":${DOTNET_CLI_HOME:-$HOME}/.dotnet/tools:"*) ;; *) PATH="$PATH:${DOTNET_CLI_HOME:-$HOME}/.dotnet/tools" ;; esac
export PATH
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1'
  if is_root && [ "$(cat "$profile" 2>/dev/null)" != "$want" ]; then
    printf '%s\n' "$want" >"$profile"
  fi
  # Once per file: a session can fire SessionStart more than once (resume, clear, compact),
  # and the block's first line is the marker that says it is already there.
  if [ -n "${CLAUDE_ENV_FILE:-}" ] && ! grep -qxF "$marker" "$CLAUDE_ENV_FILE" 2>/dev/null; then
    printf '%s\n' "$want" >>"$CLAUDE_ENV_FILE"
  fi
}

# Runs whenever root, not only before a fresh install: a container that an earlier version
# of this hook already moved to the Ubuntu SDK may still hold the stranded Microsoft-feed
# packages and the wider pin. On a clean container the purge finds nothing and changes
# nothing, and the pin is rewritten with the same content. install_sdk relies on the pin
# written here.
#
# Before anything runs dotnet, and before the root-only block below touches the system,
# refuse a global.json that could point the .NET 10 host at a branch-supplied SDK.
global_json_safe || exit 1
# A directory outside the repository for the dotnet calls that do not need global.json.
SCRATCH_DIR="$(mktemp -d)" || { log "ERROR: could not create a scratch directory."; exit 1; }
trap 'rm -rf "$SCRATCH_DIR"' EXIT
# An empty global.json stops the host's walk up to /tmp/global.json or /global.json.
printf '{}\n' >"$SCRATCH_DIR/global.json"
if is_root; then
  export DEBIAN_FRONTEND=noninteractive
  remove_microsoft_feed
  write_dotnet_pin
fi
if ! sdk_ok; then
  if ! is_root; then
    log "ERROR: no SDK under ${DOTNET_DIR} satisfies global.json, and installing one needs root. This hook never escalates; install the SDK yourself."
    exit 1
  fi
  install_sdk
  sdk_ok || { log "ERROR: dotnet-sdk-10.0 installed, but no SDK under ${DOTNET_DIR} satisfies global.json."; exit 1; }
fi
if is_root; then
  [ "$(readlink -f /usr/bin/dotnet 2>/dev/null)" = "$DOTNET_DIR/dotnet" ] || ln -sf "$DOTNET_DIR/dotnet" /usr/bin/dotnet
else
  log "Not root: /usr/bin/dotnet and /etc/profile.d/dotnet.sh are left as they are; the session environment is still written."
fi
write_profile

export DOTNET_ROOT="$DOTNET_DIR" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
purge_note=""
if [ "$PURGED_COUNT" -gt 0 ]; then
  purge_note="; purged ${PURGED_COUNT} Microsoft-feed .NET package(s)"
fi
# ---- the engine CLI, for the pinned commit ----
summary_cli="no usable vouchfx (see stderr)"
# Lower-cased: ENGINE_PIN accepts either case (scripts/bootstrap.sh), git prints lower.
pin_sha="$(head -n1 "$REPO_DIR/ENGINE_PIN" | tr -d '[:space:]' | tr 'A-F' 'a-f')"
if [[ "$pin_sha" =~ ^[0-9a-f]{40}$ ]]; then
  actual="$(cli_version)"
  if [ -z "$actual" ]; then
    # Exact release tags only (never the floating v1-rc tag); an annotated tag's commit
    # is the peeled "^{}" line. A failed lookup (network, proxy) is reported as exactly
    # that, never mistaken for "no release tag points at this commit".
    refs="" lookup_ok=false
    for attempt in 1 2; do
      if refs="$(git ls-remote --tags https://github.com/tomas-rampas/vouchfx.git 'refs/tags/v*' 2>/dev/null)"; then
        lookup_ok=true
        break
      fi
      [ "$attempt" -eq 1 ] && sleep 2
    done
    if [ "$lookup_ok" != true ]; then
      log "WARNING: could not list the engine's release tags (git ls-remote failed twice); the CLI was not installed. Re-run this hook, or install it by hand."
    else
      tag="$(printf '%s\n' "$refs" \
        | awk -v sha="$pin_sha" '$1 == sha { t = $2; sub(/^refs\/tags\//, "", t); sub(/\^\{\}$/, "", t); print t }' \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' | head -n1 || true)"
      if [ -n "$tag" ]; then
        install_cli "${tag#v}" || log "WARNING: could not install vouchfx ${tag#v}."
        actual="$(cli_version)"
      else
        log "NOTE: ENGINE_PIN ${pin_sha:0:12} is not a tagged engine release; no published CLI matches it."
      fi
    fi
  fi
  case "$actual" in
    *"+${pin_sha}") summary_cli="vouchfx ${actual} matches ENGINE_PIN" ;;
    "") ;;
    *) summary_cli="vouchfx ${actual} is installed; ENGINE_PIN is ${pin_sha:0:12} (left as is, see this hook's header)" ;;
  esac
  if [ -n "$actual" ] && ! cli_runs_plain; then
    summary_cli="${summary_cli}; the tool runs only with DOTNET_ROLL_FORWARD=Major"
  fi
else
  log "WARNING: ENGINE_PIN's first line is not a 40-character commit SHA; skipping the CLI install."
fi
echo "session-start: .NET SDK ${SDK_VERSION} (as resolved in the repository) ready${purge_note}; ${summary_cli}."
