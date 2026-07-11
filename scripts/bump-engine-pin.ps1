#Requires -Version 7.0
<#
.SYNOPSIS
    Resolves a vouchfx tag/branch/SHA to its full commit SHA and writes it
    into ENGINE_PIN.
.DESCRIPTION
    Semi-automatic helper, not full automation: it still requires a human (or
    an agent acting on a human's request) to run it, review the resulting
    diff, and open the pin-bump PR -- ENGINE_PIN's own documented philosophy
    ("a deliberate, reviewed action") is unchanged. It just removes the
    error-prone manual-lookup step: no local clone needed, and annotated tags
    are peeled automatically so you always get the COMMIT sha, never the tag
    object's own sha.
.PARAMETER Ref
    A tag name, branch name, or full 40-character commit SHA on
    https://github.com/tomas-rampas/vouchfx.
.PARAMETER Reason
    Free-text reason recorded in ENGINE_PIN's "Pin history" section. Optional
    -- a placeholder is written if omitted, reminding you to fill it in.
.EXAMPLE
    ./scripts/bump-engine-pin.ps1 v1.0.0-alpha.5 "script.csharp file field (engine PR #194)"
.EXAMPLE
    ./scripts/bump-engine-pin.ps1 a24a3f5beae0ff78ba97b69ab1f2fefa4d7eff99
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Ref,

    [Parameter(Position = 1)]
    [string]$Reason = '<fill in why this pin was advanced>'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot      = Split-Path -Parent $PSScriptRoot
$EngineRepoUrl = 'https://github.com/tomas-rampas/vouchfx.git'
$EnginePinFile = Join-Path $RepoRoot 'ENGINE_PIN'

function Write-BumpLog {
    param([string]$Message)
    Write-Host "[bump-engine-pin] $Message"
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[bump-engine-pin] ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Resolve-EngineRef {
    # Resolves ONE explicit ref pattern to the SHA in its first matching
    # line's first field, or $null if nothing matched. Explicit refs/tags/...
    # / refs/heads/... patterns (never a bare ref name) so this can never
    # ambiguously match more than one ref namespace of the same name.
    param([string]$Pattern)
    $line = git ls-remote $EngineRepoUrl $Pattern 2>$null | Select-Object -First 1
    if ($line) { ($line -split '\s+')[0] } else { $null }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Fail "git is not installed or not on PATH."
}
if (-not (Test-Path $EnginePinFile)) {
    Write-Fail "ENGINE_PIN not found at $EnginePinFile."
}

$oldSha = (Get-Content $EnginePinFile -TotalCount 1).Trim()

# -- Resolve Ref to a full commit SHA -----------------------------------------
$newSha = $null

if ($Ref -match '^[0-9a-fA-F]{40}$') {
    # Already a full SHA -- use as-is (fetchability is validated later by
    # scripts/bootstrap.ps1; this script only handles lookup + write).
    $newSha = $Ref
} else {
    Write-BumpLog "Resolving '$Ref' against $EngineRepoUrl ..."

    # 1. ANNOTATED tag, peeled (^{}) to the COMMIT it points at -- never the
    #    tag object's own SHA, which ENGINE_PIN must never hold.
    $newSha = Resolve-EngineRef "refs/tags/$Ref^{}"

    # 2. LIGHTWEIGHT tag -- ls-remote already returns the commit SHA directly.
    if (-not $newSha) {
        $newSha = Resolve-EngineRef "refs/tags/$Ref"
    }

    # 3. Branch (discouraged as a LASTING pin per ENGINE_PIN's own rationale,
    #    but still useful for a one-off lookup).
    if (-not $newSha) {
        $newSha = Resolve-EngineRef "refs/heads/$Ref"
    }
}

if (-not $newSha) {
    Write-Fail "Could not resolve '$Ref' to a commit on $EngineRepoUrl. Check the tag/branch name is correct and pushed."
}
if ($newSha -notmatch '^[0-9a-fA-F]{40}$') {
    Write-Fail "Resolved value '$newSha' is not a full 40-character commit SHA."
}

if ($newSha -eq $oldSha) {
    Write-BumpLog "ENGINE_PIN is already at $newSha -- nothing to do."
    exit 0
}

Write-BumpLog "Old pin: $oldSha"
Write-BumpLog "New pin: $newSha  (resolved from '$Ref')"

# -- Rewrite ENGINE_PIN --------------------------------------------------------
$today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
$lines = Get-Content $EnginePinFile
$lines[0] = $newSha

$historyMatch = $lines | Select-String -Pattern '^# Pin history$' -SimpleMatch:$false | Select-Object -First 1
if (-not $historyMatch) {
    Write-Fail "Could not find the '# Pin history' heading in ENGINE_PIN -- has its format changed?"
}
# Select-Object -First 1 above keeps this a scalar even if the pattern somehow
# matched more than one line; LineNumber is 1-based, so the separator line
# follows immediately.
$historyIndex = $historyMatch.LineNumber
$insertAt = $historyIndex + 1
$newEntry = @(
    "# $today`: advanced to $($newSha.Substring(0,8)) — $Reason.",
    "# Prior pin: $($oldSha.Substring(0,8))."
)
$updated = $lines[0..($insertAt - 1)] + $newEntry + $lines[$insertAt..($lines.Length - 1)]

Set-Content -Path $EnginePinFile -Value $updated -NoNewline:$false

Write-BumpLog "ENGINE_PIN updated. Review the diff, then follow ENGINE_PIN's remaining steps:"
Write-BumpLog "  1. Remove-Item -Recurse -Force .vouchfx-src -ErrorAction SilentlyContinue"
Write-BumpLog "  2. ./scripts/run-sample.ps1 all   (or .sh on macOS/Linux)"
Write-BumpLog "  3. Open a PR with just the pin bump (plus any required sample changes)."
