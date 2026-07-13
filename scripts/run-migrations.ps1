#Requires -Version 7.0
<#
.SYNOPSIS
    Builds the shared orders-dotnet image and runs all three migrations/*/ported suites
    through the pinned vouchfx engine CLI.
.DESCRIPTION
    Mirrors scripts/run-sample.ps1's conventions -- see that file's long comments on the
    Out-Host piping / return [int]$rc / array-wrapping discipline this script follows for
    the same reason: a leaked pipeline value here would silently coerce a real suite
    failure into exit 0, exactly as documented there (the false-green bug is real history).

    Migrations run strictly sequentially: each suite stands up its own Aspire/Testcontainers
    topology via DCP, and running two topologies concurrently on one machine causes DCP
    port/network contention (see docs/RUNNING.md).
.EXAMPLE
    ./scripts/run-migrations.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot      = Split-Path -Parent $PSScriptRoot
$MigrationsDir = Join-Path $RepoRoot 'migrations'
$VouchfxSrcDir = Join-Path $RepoRoot '.vouchfx-src'
$CliProject    = Join-Path $VouchfxSrcDir 'src/Cli/Vouchfx.Cli/Vouchfx.Cli.csproj'
$OutDir        = Join-Path $RepoRoot 'out'
$OrdersAppDir  = Join-Path $RepoRoot 'samples/orders-dotnet/app'
$OrdersImage   = 'vouchfx-samples-orders-dotnet:local'

function Write-MigrationLog {
    param([string]$Message)
    Write-Host "[run-migrations] $Message"
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[run-migrations] ERROR: $Message" -ForegroundColor Red
    exit 1
}

# -- Ensure the engine CLI is bootstrapped ------------------------------------
if (-not (Test-Path $VouchfxSrcDir)) {
    Write-MigrationLog ".vouchfx-src not found -- running scripts/bootstrap.ps1 first."
    & (Join-Path $PSScriptRoot 'bootstrap.ps1')
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "bootstrap.ps1 failed; cannot continue."
    }
}

if (-not (Test-Path $CliProject)) {
    Write-Fail "Engine CLI project not found at $CliProject after bootstrap. Re-run scripts/bootstrap.ps1 and check its output."
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# -- Build the shared orders-dotnet image, once -------------------------------
# All three migrations port tests against the same samples/orders-dotnet/app, so the image
# is built once here rather than once per migration (see samples/orders-dotnet/README.md
# for what the image contains).
Write-MigrationLog "=== docker build $OrdersImage ==="
docker build -t $OrdersImage "$OrdersAppDir" | Out-Host
$buildRc = [int]$LASTEXITCODE
if ($buildRc -ne 0) {
    Write-Fail "docker build failed for $OrdersImage (exit $buildRc)."
}

# migrations/from-postman's ported suite resolves an X-Api-Key header via
# ${secret:env/VOUCHFX_SAMPLES_ORDERS_API_KEY} (secrets resolve from the run environment at
# step-execution time, never at compile time -- engine blueprint §17). The orders-dotnet
# app does not itself validate this header -- it stands in for a real deployment's API
# gateway/auth proxy. See migrations/from-postman/README.md.
$env:VOUCHFX_SAMPLES_ORDERS_API_KEY = 'local-dev-key-not-real'

# Invoke-Migration runs a single migrations/<Name>/ported suite. It never calls
# Write-Fail/exit for a suite-scoped problem -- every failure path returns a non-zero
# status so the loop below can continue past a broken suite and report a full summary
# at the end.
function Invoke-Migration {
    param([string]$Name)

    $portedDir = Join-Path (Join-Path $MigrationsDir $Name) 'ported'
    $junitOut  = Join-Path $OutDir "migrations-$Name-results.xml"
    $htmlOut   = Join-Path $OutDir "migrations-$Name-report.html"

    if (-not (Test-Path $portedDir)) {
        Write-MigrationLog "Migration '$Name' has no ported/ directory at $portedDir."
        return 1
    }

    Write-MigrationLog "=== ${Name}: running suite (migrations/$Name/ported) ==="
    $dotnetArgs = @(
        'run', '--project', $CliProject, '-c', 'Release', '--no-build', '--',
        'run', $portedDir,
        '--junit', $junitOut,
        '--html', $htmlOut,
        '--fail-on-env-error',
        '--fail-on-inconclusive'
    )
    # Pipe to Out-Host for the same reason run-sample.ps1 does: this keeps the native
    # process's stdout/stderr out of Invoke-Migration's success stream, so 'return [int]$rc'
    # below is the ONLY statement that reaches the caller's pipeline.
    & dotnet @dotnetArgs | Out-Host
    $rc = [int]$LASTEXITCODE

    Write-MigrationLog "=== ${Name}: exit code $rc ==="
    if (Test-Path $junitOut) { Write-MigrationLog "JUnit report: $junitOut" }
    if (Test-Path $htmlOut)  { Write-MigrationLog "HTML report:  $htmlOut" }

    return [int]$rc
}

# -- Execute --------------------------------------------------------------------
# Fixed, deliberate order -- from-postman first (cheapest, REST-only), then from-xunit,
# then from-specflow (the fullest four-family flow) -- rather than a directory listing, so
# a new migrations/<name> directory never silently joins the run before it is ready.
#
# The @(...) wrap matters here for the same reason run-sample.ps1 wraps its $targets
# assignment: without it, PowerShell's pipeline semantics can unroll a literal array
# expression back to something Set-StrictMode chokes on downstream. Kept explicit even
# though this array is always 3 elements, so the invariant holds if that ever changes.
$Migrations = @('from-postman', 'from-xunit', 'from-specflow')

$summaryNames = @()
$summaryRcs   = @()
$overallRc    = 0

foreach ($name in $Migrations) {
    # [int](...) is a defence-in-depth cast, not the fix itself: Invoke-Migration's own
    # single `return [int]$rc` is what keeps this a scalar. If a future edit accidentally
    # reintroduces a leaked bare native/pipeline call inside the function, this cast fails
    # loudly (cannot convert Object[] to int) instead of silently coercing to 0.
    $rc = [int](Invoke-Migration -Name $name)
    $summaryNames += $name
    $summaryRcs   += $rc
    if ($rc -ne 0) { $overallRc = $rc }
}

Write-MigrationLog "=== Summary ==="
for ($i = 0; $i -lt $summaryNames.Count; $i++) {
    Write-MigrationLog "  $($summaryNames[$i]): exit $($summaryRcs[$i])"
}

exit [int]$overallRc
