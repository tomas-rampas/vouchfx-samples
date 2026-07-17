#Requires -Version 7.0
<#
.SYNOPSIS
    Fetches the pinned vouchfx engine commit and builds its CLI.
.DESCRIPTION
    Reads the pinned engine commit SHA from ENGINE_PIN at the repo root,
    shallow-fetches exactly that commit from https://github.com/tomas-rampas/vouchfx
    into .vouchfx-src/, and builds the engine CLI
    (src/Cli/Vouchfx.Cli/Vouchfx.Cli.csproj) in Release configuration. Building
    the CLI project performs the NuGet restore that materialises the Aspire
    AppHost SDK's DCP binaries -- no separate Aspire workload install is needed.

    Idempotent: if .vouchfx-src is already checked out at the pinned SHA, the
    fetch is skipped (the build step still runs, but is a fast no-op
    incremental build).
.EXAMPLE
    ./scripts/bootstrap.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot      = Split-Path -Parent $PSScriptRoot
$EngineRepoUrl = 'https://github.com/tomas-rampas/vouchfx.git'
$VouchfxSrcDir = Join-Path $RepoRoot '.vouchfx-src'
$CliProjectRel = 'src/Cli/Vouchfx.Cli/Vouchfx.Cli.csproj'

function Write-BootstrapLog {
    param([string]$Message)
    Write-Host "[bootstrap] $Message"
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[bootstrap] ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Assert-Success {
    param([string]$Message)
    if ($LASTEXITCODE -ne 0) {
        Write-Fail $Message
    }
}

# -- Preflight: required tools ------------------------------------------------
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Fail "git is not installed or not on PATH. Install it from https://git-scm.com/downloads and re-run."
}
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Fail ".NET SDK is not installed or not on PATH. Install .NET 8 SDK (8.0.400 or later) from https://dotnet.microsoft.com/download/dotnet/8.0 and re-run."
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Fail "Docker is not installed or not on PATH. Install Docker Desktop (or the Docker Engine) from https://www.docker.com/products/docker-desktop/ -- the engine orchestrates test topology via containers and cannot run without it."
}
docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Docker is installed but the daemon is not responding. Start Docker Desktop (or the Docker service) and re-run."
}

$dotnetVersion = $null
try {
    $dotnetVersion = (dotnet --version 2>$null)
} catch {
    $dotnetVersion = $null
}
Write-BootstrapLog "Using dotnet $(if ($dotnetVersion) { $dotnetVersion } else { '<unknown>' })"

# -- Read and validate ENGINE_PIN ----------------------------------------------
$EnginePinFile = Join-Path $RepoRoot 'ENGINE_PIN'
if (-not (Test-Path $EnginePinFile)) {
    Write-Fail "ENGINE_PIN not found at $EnginePinFile."
}

$EngineSha = (Get-Content -Path $EnginePinFile -TotalCount 1).Trim()

if ($EngineSha -match '^0{40}$') {
    Write-Fail "ENGINE_PIN still holds the placeholder SHA (all zeros). Stamp it with a real 40-character commit SHA from https://github.com/tomas-rampas/vouchfx before running bootstrap."
}

if ($EngineSha -notmatch '^[0-9a-fA-F]{40}$') {
    Write-Fail "ENGINE_PIN's first line ('$EngineSha') is not a full 40-character commit SHA. A short SHA or a branch/tag name will not work -- shallow cross-repo fetches require the full SHA."
}

Write-BootstrapLog "Pinned engine commit: $EngineSha"

# -- Fetch the pinned commit (skip if already checked out at that SHA) -------
$CurrentSha = $null
if (Test-Path (Join-Path $VouchfxSrcDir '.git')) {
    try {
        $CurrentSha = (git -C $VouchfxSrcDir rev-parse HEAD 2>$null)
        if ($CurrentSha) { $CurrentSha = $CurrentSha.Trim() }
    } catch {
        $CurrentSha = $null
    }
}

if ($CurrentSha -eq $EngineSha) {
    Write-BootstrapLog ".vouchfx-src is already at the pinned commit ($($EngineSha.Substring(0,12))...) -- skipping fetch."
} else {
    if (Test-Path $VouchfxSrcDir) {
        $shortCurrent = if ($CurrentSha) { $CurrentSha } else { '<none>' }
        Write-BootstrapLog "Removing stale .vouchfx-src (was at $shortCurrent, pin is $($EngineSha.Substring(0,12))...)."
        Remove-Item -Recurse -Force $VouchfxSrcDir
    }

    Write-BootstrapLog "Fetching $EngineSha from $EngineRepoUrl (shallow, depth 1)..."
    New-Item -ItemType Directory -Force -Path $VouchfxSrcDir | Out-Null

    git -C $VouchfxSrcDir init -q
    Assert-Success "git init failed in $VouchfxSrcDir."

    git -C $VouchfxSrcDir remote add origin $EngineRepoUrl
    Assert-Success "git remote add failed in $VouchfxSrcDir."

    git -C $VouchfxSrcDir fetch --depth 1 origin $EngineSha
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -Recurse -Force $VouchfxSrcDir -ErrorAction SilentlyContinue
        Write-Fail "Could not fetch commit $EngineSha from $EngineRepoUrl. Check the SHA in ENGINE_PIN is correct, reachable in the engine's history, and that you have network access to GitHub."
    }

    git -C $VouchfxSrcDir checkout -q FETCH_HEAD
    Assert-Success "git checkout FETCH_HEAD failed in $VouchfxSrcDir."

    Write-BootstrapLog "Checked out $EngineSha into .vouchfx-src/"
}

# -- Build the engine CLI -------------------------------------------------------
$CliProjectPath = Join-Path $VouchfxSrcDir $CliProjectRel
if (-not (Test-Path $CliProjectPath)) {
    Write-Fail "Expected CLI project not found at $CliProjectPath. The engine's repo layout may have changed since this pin was set -- check that src/Cli/Vouchfx.Cli/ exists at commit $EngineSha."
}

Write-BootstrapLog "Building engine CLI (Release)... this also restores the Aspire AppHost SDK's DCP binaries."
dotnet build $CliProjectPath -c Release
Assert-Success "dotnet build failed for $CliProjectPath. See the build output above for details."

Write-BootstrapLog "Bootstrap complete. Engine CLI built from commit $EngineSha."
# Derive the sample list dynamically (mirroring run-sample.ps1's Get-AvailableSample,
# including its missing-directory guard — a corrupted checkout must not fail bootstrap
# after the real work succeeded) so this hint can never drift from the samples the
# runner actually offers.
$SamplesDir = Join-Path $RepoRoot 'samples'
$SampleNames = @(if (Test-Path $SamplesDir) {
    Get-ChildItem -Path $SamplesDir -Directory | Select-Object -ExpandProperty Name | Sort-Object
})
Write-BootstrapLog ("Next: scripts/run-sample.ps1 <{0}|all>" -f ($SampleNames -join '|'))
