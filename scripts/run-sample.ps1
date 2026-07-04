#Requires -Version 7.0
<#
.SYNOPSIS
    Builds a sample's Docker image and runs its .e2e.yaml suite through the
    pinned vouchfx engine CLI.
.PARAMETER SampleName
    The sample directory name under samples/ (e.g. orders-dotnet), or "all" to
    run every sample sequentially.
.DESCRIPTION
    Samples run strictly sequentially, even under "all": each suite stands up
    its own Aspire/Testcontainers topology via DCP, and running two topologies
    concurrently on one machine causes DCP port/network contention (see
    docs/RUNNING.md).
.EXAMPLE
    ./scripts/run-sample.ps1 orders-dotnet
.EXAMPLE
    ./scripts/run-sample.ps1 all
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$SampleName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot      = Split-Path -Parent $PSScriptRoot
$SamplesDir    = Join-Path $RepoRoot 'samples'
$VouchfxSrcDir = Join-Path $RepoRoot '.vouchfx-src'
$CliProject    = Join-Path $VouchfxSrcDir 'src/Cli/Vouchfx.Cli/Vouchfx.Cli.csproj'
$OutDir        = Join-Path $RepoRoot 'out'

function Write-SampleLog {
    param([string]$Message)
    Write-Host "[run-sample] $Message"
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[run-sample] ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Get-AvailableSample {
    if (-not (Test-Path $SamplesDir)) {
        return @()
    }
    Get-ChildItem -Path $SamplesDir -Directory | Select-Object -ExpandProperty Name | Sort-Object
}

function Show-Usage {
    Write-Host "Usage: scripts/run-sample.ps1 <sample-name>|all"
    Write-Host ""
    Write-Host "Available samples:"
    foreach ($s in (Get-AvailableSample)) {
        Write-Host "  - $s"
    }
    Write-Host "  - all   (run every sample above, one at a time)"
}

# -- Argument validation -------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($SampleName)) {
    Show-Usage
    exit 2
}

$AvailableSamples = @(Get-AvailableSample)

if ($SampleName -ne 'all' -and ($AvailableSamples -notcontains $SampleName)) {
    Write-Host "[run-sample] ERROR: unknown sample `"$SampleName`"" -ForegroundColor Red
    Write-Host ""
    Show-Usage
    exit 2
}

# -- Ensure the engine CLI is bootstrapped ------------------------------------
if (-not (Test-Path $VouchfxSrcDir)) {
    Write-SampleLog ".vouchfx-src not found -- running scripts/bootstrap.ps1 first."
    & (Join-Path $PSScriptRoot 'bootstrap.ps1')
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "bootstrap.ps1 failed; cannot continue."
    }
}

if (-not (Test-Path $CliProject)) {
    Write-Fail "Engine CLI project not found at $CliProject after bootstrap. Re-run scripts/bootstrap.ps1 and check its output."
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Invoke-Sample builds and tests a single sample. It never calls Write-Fail/exit
# for a sample-scoped problem -- every failure path returns a non-zero status
# so the "all" loop can continue past a broken sample and report a full
# summary at the end.
function Invoke-Sample {
    param([string]$Name)

    $image    = "vouchfx-samples-${Name}:local"
    $appDir   = Join-Path (Join-Path $SamplesDir $Name) 'app'
    $testsDir = Join-Path (Join-Path $SamplesDir $Name) 'tests'
    $junitOut = Join-Path $OutDir "$Name-results.xml"
    $htmlOut  = Join-Path $OutDir "$Name-report.html"

    if (-not (Test-Path $appDir)) {
        Write-SampleLog "Sample '$Name' has no app/ directory at $appDir."
        return 1
    }
    if (-not (Test-Path $testsDir)) {
        Write-SampleLog "Sample '$Name' has no tests/ directory at $testsDir."
        return 1
    }

    Write-SampleLog "=== ${Name}: docker build $image ==="
    docker build -t $image "$appDir"
    if ($LASTEXITCODE -ne 0) {
        Write-SampleLog "docker build failed for $Name."
        return 1
    }

    Write-SampleLog "=== ${Name}: running suite (samples/$Name/tests) ==="
    $dotnetArgs = @(
        'run', '--project', $CliProject, '-c', 'Release', '--no-build', '--',
        'run', $testsDir,
        '--junit', $junitOut,
        '--html', $htmlOut,
        '--fail-on-env-error',
        '--fail-on-inconclusive'
    )
    & dotnet @dotnetArgs
    $rc = $LASTEXITCODE

    Write-SampleLog "=== ${Name}: exit code $rc ==="
    if (Test-Path $junitOut) { Write-SampleLog "JUnit report: $junitOut" }
    if (Test-Path $htmlOut)  { Write-SampleLog "HTML report:  $htmlOut" }

    return $rc
}

# -- Execute --------------------------------------------------------------------
$targets = if ($SampleName -eq 'all') { $AvailableSamples } else { @($SampleName) }

$summaryNames = @()
$summaryRcs   = @()
$overallRc    = 0

foreach ($name in $targets) {
    $rc = Invoke-Sample -Name $name
    $summaryNames += $name
    $summaryRcs   += $rc
    if ($rc -ne 0) { $overallRc = $rc }
}

if ($targets.Count -gt 1) {
    Write-SampleLog "=== Summary ==="
    for ($i = 0; $i -lt $summaryNames.Count; $i++) {
        Write-SampleLog "  $($summaryNames[$i]): exit $($summaryRcs[$i])"
    }
}

exit $overallRc
