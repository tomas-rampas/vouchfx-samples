#Requires -Version 7.0
<#
.SYNOPSIS
    Runs Docker-free subprocess regressions for scripts/run-sample.ps1.
.DESCRIPTION
    Copies the runner into temporary sample repositories and replaces Docker
    and dotnet with native stubs. No containers, certificates or engine builds
    are created. Run with: pwsh -NoProfile -File scripts/tests/test-run-sample.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'run-sample.ps1'
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$scratch = Join-Path $tempRoot ("vouchfx sample runner tests " + [guid]::NewGuid().ToString('N'))
$shell = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
$utf8 = [System.Text.UTF8Encoding]::new($false)
$passed = 0
$environmentNames = @(
    'PATH', 'VOUCHFX_SAMPLES_TEST_LOG', 'VOUCHFX_SAMPLES_TEST_EXPECT_FIXTURE',
    'VOUCHFX_SAMPLES_TEST_DOCKER_EXIT', 'VOUCHFX_SAMPLES_TEST_RUNNER_BUILD_EXIT',
    'VOUCHFX_SAMPLES_TEST_CLI_EXIT', 'VOUCHFX_SAMPLES_TEST_VERSION',
    'VOUCHFX_SAMPLES_TEST_VERSION_EXIT', 'VOUCHFX_SAMPLES_CLI', 'VOUCHFX_SAMPLES_CLI_VERSION',
    'VOUCHFX_SAMPLE_DOTNET_VERSION', 'VOUCHFX_SAMPLE_DOTNET_SDK_IMAGE',
    'VOUCHFX_SAMPLE_DOTNET_RUNTIME_IMAGE'
)
$originalEnvironment = @{}
foreach ($name in $environmentNames) {
    $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}

function Write-File {
    param([string]$Path, [string]$Content)
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-Case {
    param([string]$Name, [switch]$Installed)
    $root = Join-Path $scratch $Name
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'scripts')
    Copy-Item -LiteralPath $source -Destination (Join-Path $root 'scripts/run-sample.ps1')
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $source) 'dotnet-images.properties') -Destination (Join-Path $root 'scripts/dotnet-images.properties')
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $source) 'run-migrations.ps1') -Destination (Join-Path $root 'scripts/run-migrations.ps1')
    if (-not $Installed) {
        Write-File (Join-Path $root '.vouchfx-src/src/Cli/Vouchfx.Cli/Vouchfx.Cli.csproj') '<Project />'
    }
    Write-File (Join-Path $root 'scripts/bootstrap.ps1') '[System.IO.File]::AppendAllText($env:VOUCHFX_SAMPLES_TEST_LOG, "bootstrap`n"); exit 89'
    $env:VOUCHFX_SAMPLES_TEST_LOG = Join-Path $root 'calls.log'
    $env:VOUCHFX_SAMPLES_TEST_EXPECT_FIXTURE = ''
    $env:VOUCHFX_SAMPLES_TEST_DOCKER_EXIT = '0'
    $env:VOUCHFX_SAMPLES_TEST_RUNNER_BUILD_EXIT = '0'
    $env:VOUCHFX_SAMPLES_TEST_CLI_EXIT = '0'
    $env:VOUCHFX_SAMPLES_TEST_VERSION = '1.0.0-sample-test+not-released'
    $env:VOUCHFX_SAMPLES_TEST_VERSION_EXIT = '0'
    $env:VOUCHFX_SAMPLES_CLI = ''
    $env:VOUCHFX_SAMPLES_CLI_VERSION = ''
    $env:VOUCHFX_SAMPLE_DOTNET_VERSION = ''
    $env:VOUCHFX_SAMPLE_DOTNET_SDK_IMAGE = ''
    $env:VOUCHFX_SAMPLE_DOTNET_RUNTIME_IMAGE = ''
    if ($Installed) {
        $env:VOUCHFX_SAMPLES_CLI = Join-Path $bin $(if ($IsWindows) { 'candidate cli.cmd' } else { 'candidate cli' })
        $env:VOUCHFX_SAMPLES_CLI_VERSION = $env:VOUCHFX_SAMPLES_TEST_VERSION
    }
    return $root
}

function New-Sample {
    param(
        [string]$Root, [string]$Name, [switch]$App, [switch]$Runner,
        [switch]$Setup, [int]$SetupExit = 0, [switch]$SetupThrows,
        [switch]$WithoutTests
    )
    $sample = Join-Path $Root "samples/$Name"
    $null = New-Item -ItemType Directory -Force -Path $sample
    if (-not $WithoutTests) {
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $sample 'tests')
    }
    if ($App) { $null = New-Item -ItemType Directory -Force -Path (Join-Path $sample 'app') }
    if ($Runner) { Write-File (Join-Path $sample 'runner/Test.csproj') '<Project />' }
    if ($Setup) {
        $ending = if ($SetupThrows) { "throw 'fixture generation failed'" } else { "exit $SetupExit" }
        $script = @'
[System.IO.File]::AppendAllText($env:VOUCHFX_SAMPLES_TEST_LOG, "setup SAMPLE_NAME`n")
Write-Output 'setup output must not enter the integer result'
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'tests/generated.txt'), 'fixture')
SETUP_ENDING
'@
        Write-File (Join-Path $sample 'setup.ps1') ($script.Replace('SAMPLE_NAME', $Name).Replace('SETUP_ENDING', $ending))
    }
    return $sample
}

function Invoke-Case {
    param([string]$Root, [string]$Target, [int]$ExpectedExit)
    $console = @(& $shell -NoProfile -File (Join-Path $Root 'scripts/run-sample.ps1') $Target 2>&1)
    $exitCode = [int]$LASTEXITCODE
    $output = $console -join "`n"
    Assert-True ($exitCode -eq $ExpectedExit) "Expected exit $ExpectedExit, got $exitCode.`n$output"
    $calls = if (Test-Path -LiteralPath $env:VOUCHFX_SAMPLES_TEST_LOG) {
        [System.IO.File]::ReadAllLines($env:VOUCHFX_SAMPLES_TEST_LOG)
    } else { @() }
    return [pscustomobject]@{ Output = $output; Calls = @($calls) }
}

try {
    $bin = Join-Path $scratch 'bin'
    if ($IsWindows) {
        $stub = @'
@echo off
echo COMMAND %*>>"%VOUCHFX_SAMPLES_TEST_LOG%"
echo COMMAND native output must not enter the integer result
if defined VOUCHFX_SAMPLES_TEST_EXPECT_FIXTURE if not exist "%VOUCHFX_SAMPLES_TEST_EXPECT_FIXTURE%" exit /b 91
EXIT_RULE
'@
        Write-File (Join-Path $bin 'docker.cmd') ($stub.Replace('COMMAND', 'docker').Replace('EXIT_RULE', 'exit /b %VOUCHFX_SAMPLES_TEST_DOCKER_EXIT%'))
        Write-File (Join-Path $bin 'dotnet.cmd') ($stub.Replace('COMMAND', 'dotnet').Replace('EXIT_RULE', "if `"%1`"==`"build`" exit /b %VOUCHFX_SAMPLES_TEST_RUNNER_BUILD_EXIT%`r`nexit /b %VOUCHFX_SAMPLES_TEST_CLI_EXIT%"))
        $cliStub = @'
@echo off
echo cli %*>>"%VOUCHFX_SAMPLES_TEST_LOG%"
if "%1"=="--version" (
  echo %VOUCHFX_SAMPLES_TEST_VERSION%
  exit /b %VOUCHFX_SAMPLES_TEST_VERSION_EXIT%
)
echo cli native output must not enter the integer result
if defined VOUCHFX_SAMPLES_TEST_EXPECT_FIXTURE if not exist "%VOUCHFX_SAMPLES_TEST_EXPECT_FIXTURE%" exit /b 91
exit /b %VOUCHFX_SAMPLES_TEST_CLI_EXIT%
'@
        Write-File (Join-Path $bin 'candidate cli.cmd') $cliStub
    }
    else {
        $stub = @'
#!/bin/sh
printf '%s\n' "COMMAND $*" >> "$VOUCHFX_SAMPLES_TEST_LOG"
printf '%s\n' 'COMMAND native output must not enter the integer result'
if [ -n "$VOUCHFX_SAMPLES_TEST_EXPECT_FIXTURE" ] && [ ! -f "$VOUCHFX_SAMPLES_TEST_EXPECT_FIXTURE" ]; then exit 91; fi
EXIT_RULE
'@
        Write-File (Join-Path $bin 'docker') ($stub.Replace('COMMAND', 'docker').Replace('EXIT_RULE', 'exit "$VOUCHFX_SAMPLES_TEST_DOCKER_EXIT"'))
        Write-File (Join-Path $bin 'dotnet') ($stub.Replace('COMMAND', 'dotnet').Replace('EXIT_RULE', "if [ `"`$1`" = build ]; then exit `"`$VOUCHFX_SAMPLES_TEST_RUNNER_BUILD_EXIT`"; fi`nexit `"`$VOUCHFX_SAMPLES_TEST_CLI_EXIT`""))
        $cliStub = @'
#!/bin/sh
printf '%s\n' "cli $*" >> "$VOUCHFX_SAMPLES_TEST_LOG"
if [ "$1" = --version ]; then printf '%s\n' "$VOUCHFX_SAMPLES_TEST_VERSION"; exit "$VOUCHFX_SAMPLES_TEST_VERSION_EXIT"; fi
printf '%s\n' 'cli native output must not enter the integer result'
if [ -n "$VOUCHFX_SAMPLES_TEST_EXPECT_FIXTURE" ] && [ ! -f "$VOUCHFX_SAMPLES_TEST_EXPECT_FIXTURE" ]; then exit 91; fi
exit "$VOUCHFX_SAMPLES_TEST_CLI_EXIT"
'@
        Write-File (Join-Path $bin 'candidate cli') $cliStub
        & chmod +x (Join-Path $bin 'docker') (Join-Path $bin 'dotnet') (Join-Path $bin 'candidate cli')
        Assert-True ($LASTEXITCODE -eq 0) 'Could not make native stubs executable.'
    }
    $env:PATH = $bin + [System.IO.Path]::PathSeparator + $originalEnvironment['PATH']

    $root = New-Case 'dependency only'
    $sample = New-Sample $root 'dependency' -Setup
    $env:VOUCHFX_SAMPLES_TEST_EXPECT_FIXTURE = Join-Path $sample 'tests/generated.txt'
    $result = Invoke-Case $root 'dependency' 0
    Assert-True ($result.Calls.Count -eq 2 -and $result.Calls[0] -eq 'setup dependency' -and $result.Calls[1] -like 'dotnet run *') 'Dependency-only setup must precede the CLI and must not build an image.'
    Assert-True ($result.Calls[1] -like '*--fail-on-env-error*--fail-on-inconclusive*') 'CLI verdict flags are required.'
    $passed++

    $root = New-Case 'setup before image'
    $sample = New-Sample $root 'app' -App -Setup
    $env:VOUCHFX_SAMPLES_TEST_EXPECT_FIXTURE = Join-Path $sample 'tests/generated.txt'
    $result = Invoke-Case $root 'app' 0
    Assert-True ($result.Calls.Count -eq 3 -and $result.Calls[0] -eq 'setup app' -and $result.Calls[1] -like 'docker build *' -and $result.Calls[2] -like 'dotnet run *') 'Setup must precede both image build and CLI.'
    $passed++

    $root = New-Case 'setup exit'
    $null = New-Sample $root 'failed' -App -Setup -SetupExit 7
    $result = Invoke-Case $root 'failed' 7
    Assert-True ($result.Calls.Count -eq 1 -and $result.Calls[0] -eq 'setup failed') 'A failing setup must prevent Docker and CLI execution.'
    $passed++

    $root = New-Case 'setup exception'
    $null = New-Sample $root 'failed' -Setup -SetupThrows
    $result = Invoke-Case $root 'failed' 1
    Assert-True ($result.Calls.Count -eq 1) 'A setup exception must prevent CLI execution.'
    $passed++

    $root = New-Case 'image build failure'
    $null = New-Sample $root 'app' -App
    $env:VOUCHFX_SAMPLES_TEST_DOCKER_EXIT = '23'
    $result = Invoke-Case $root 'app' 23
    Assert-True ($result.Calls.Count -eq 1 -and $result.Calls[0] -like 'docker build *') 'An image-build failure must prevent CLI execution and preserve its integer exit.'
    $passed++

    $root = New-Case 'runner build failure'
    $null = New-Sample $root 'custom' -Runner
    $env:VOUCHFX_SAMPLES_TEST_RUNNER_BUILD_EXIT = '17'
    $result = Invoke-Case $root 'custom' 17
    Assert-True ($result.Calls.Count -eq 1 -and $result.Calls[0] -like 'dotnet build *') 'A runner-build failure must prevent suite execution.'
    $passed++

    $root = New-Case 'custom runner'
    $null = New-Sample $root 'custom' -Runner
    $result = Invoke-Case $root 'custom' 0
    Assert-True ($result.Calls.Count -eq 2 -and $result.Calls[0] -like 'dotnet build *' -and $result.Calls[1] -like 'dotnet run *') 'A dependency-only custom runner must build and run without an image.'
    Assert-True ($result.Calls[1] -notlike '*--fail-on-*') 'Custom runners must retain their own verdict taxonomy.'
    $passed++

    $root = New-Case 'missing tests'
    $null = New-Sample $root 'missing' -WithoutTests -Setup
    $result = Invoke-Case $root 'missing' 1
    Assert-True ($result.Calls.Count -eq 0) 'Missing tests must fail before setup or native commands.'
    $passed++

    $root = New-Case 'all five samples'
    $null = New-Sample $root 'a-setup' -Setup -SetupExit 7
    $null = New-Sample $root 'b-dependency'
    $null = New-Sample $root 'c-app' -App
    $null = New-Sample $root 'd-runner' -Runner
    $null = New-Sample $root 'e-dependency'
    $env:VOUCHFX_SAMPLES_TEST_DOCKER_EXIT = '23'
    $env:VOUCHFX_SAMPLES_TEST_RUNNER_BUILD_EXIT = '17'
    $env:VOUCHFX_SAMPLES_TEST_CLI_EXIT = '4'
    $result = Invoke-Case $root 'all' 4
    Assert-True ($result.Calls.Count -eq 5) 'All must continue through every sample after earlier failures.'
    foreach ($entry in @('a-setup: exit 7', 'b-dependency: exit 4', 'c-app: exit 23', 'd-runner: exit 17', 'e-dependency: exit 4')) {
        Assert-True ($result.Output.Contains($entry)) "Missing summary entry: $entry"
    }
    $passed++

    $root = New-Case 'installed dependency' -Installed
    $sample = New-Sample $root 'dependency' -Setup
    $env:VOUCHFX_SAMPLES_TEST_EXPECT_FIXTURE = Join-Path $sample 'tests/generated.txt'
    $result = Invoke-Case $root 'dependency' 0
    Assert-True ($result.Calls.Count -eq 3 -and $result.Calls[0] -eq 'cli --version' -and $result.Calls[1] -eq 'setup dependency' -and $result.Calls[2] -like 'cli run *') 'Installed mode must check the version, prepare fixtures, and run without source or an image.'
    Assert-True ($result.Calls[2] -like '*--fail-on-env-error*--fail-on-inconclusive*') 'Installed CLI must receive strict verdict flags.'
    Assert-True (-not (Test-Path (Join-Path $root '.vouchfx-src'))) 'Installed mode must not bootstrap a source checkout.'
    $passed++

    $root = New-Case 'installed image ordering' -Installed
    $null = New-Sample $root 'app' -App -Setup
    $result = Invoke-Case $root 'app' 0
    Assert-True ($result.Calls.Count -eq 4 -and $result.Calls[0] -eq 'cli --version' -and $result.Calls[1] -eq 'setup app' -and $result.Calls[2] -like 'docker build *' -and $result.Calls[3] -like 'cli run *') 'Installed version verification must precede setup, Docker and CLI execution.'
    $passed++

    $root = New-Case 'installed version mismatch' -Installed
    $null = New-Sample $root 'app' -App -Setup
    $env:VOUCHFX_SAMPLES_TEST_VERSION = '1.0.0-wrong-build'
    $result = Invoke-Case $root 'all' 1
    Assert-True ($result.Calls.Count -eq 1 -and $result.Calls[0] -eq 'cli --version') 'A version mismatch must stop all before setup or Docker.'
    $passed++

    $root = New-Case 'installed version failure' -Installed
    $null = New-Sample $root 'app' -App
    $env:VOUCHFX_SAMPLES_TEST_VERSION_EXIT = '9'
    $result = Invoke-Case $root 'all' 1
    Assert-True ($result.Calls.Count -eq 1) 'A failed version command must stop all.'
    $passed++

    $root = New-Case 'installed missing expected version' -Installed
    $null = New-Sample $root 'app' -App
    $env:VOUCHFX_SAMPLES_CLI_VERSION = ''
    $result = Invoke-Case $root 'app' 1
    Assert-True ($result.Calls.Count -eq 0) 'Installed mode must require an explicit expected version.'
    $passed++

    $root = New-Case 'installed missing executable setting' -Installed
    $null = New-Sample $root 'app' -App
    $env:VOUCHFX_SAMPLES_CLI = ''
    $result = Invoke-Case $root 'app' 1
    Assert-True ($result.Calls.Count -eq 0) 'An expected version alone must not fall back to source.'
    $passed++

    $root = New-Case 'installed missing executable file' -Installed
    $null = New-Sample $root 'app' -App
    $env:VOUCHFX_SAMPLES_CLI = Join-Path $root 'missing executable'
    $result = Invoke-Case $root 'app' 1
    Assert-True ($result.Calls.Count -eq 0) 'A missing executable must fail without bootstrap or Docker.'
    $passed++

    $root = New-Case 'installed CLI environment failure' -Installed
    $null = New-Sample $root 'dependency'
    $env:VOUCHFX_SAMPLES_TEST_CLI_EXIT = '3'
    $result = Invoke-Case $root 'all' 3
    Assert-True ($result.Calls.Count -eq 2 -and $result.Calls[1] -like 'cli run *') 'Installed CLI failure must reach the aggregate exit.'
    $passed++

    $root = New-Case 'installed custom runner refusal' -Installed
    $null = New-Sample $root 'a-custom' -Runner -App -Setup
    $null = New-Sample $root 'b-standard'
    $result = Invoke-Case $root 'all' 1
    Assert-True ($result.Calls.Count -eq 2 -and $result.Calls[1] -like '*b-standard*') 'Installed all must reject the custom source runner and still execute standard samples.'
    Assert-True ($result.Output.Contains('Unset VOUCHFX_SAMPLES_CLI') -and $result.Output.Contains('a-custom: exit 1') -and $result.Output.Contains('b-standard: exit 0')) 'Custom-runner refusal must be actionable and visible in the summary.'
    $passed++

    $root = New-Case 'source Compose variant discovery'
    $null = New-Sample $root 'orders-dotnet' -App
    $null = New-Sample $root 'orders-dotnet-compose'
    $result = Invoke-Case $root 'all' 0
    Assert-True ($result.Calls.Count -eq 3) 'Source discovery must build only the inline app, then dispatch both suites.'
    Assert-True ($result.Calls[0] -like 'docker build *orders-dotnet:local*') 'The inline app must retain its build.'
    Assert-True ($result.Calls[1] -like 'dotnet run *orders-dotnet*tests*' -and $result.Calls[2] -like 'dotnet run *orders-dotnet-compose*tests*') 'Both sample directories must be selected in order.'
    $passed++

    $root = New-Case 'installed Compose variant selection' -Installed
    $null = New-Sample $root 'orders-dotnet-compose'
    $result = Invoke-Case $root 'orders-dotnet-compose' 0
    Assert-True ($result.Calls.Count -eq 2 -and $result.Calls[0] -eq 'cli --version') 'Compose mode must not manually build a duplicated app.'
    Assert-True ($result.Calls[1] -like 'cli run *orders-dotnet-compose*tests*--fail-on-env-error*--fail-on-inconclusive*') 'The explicit candidate must receive the Compose suite and strict verdict flags.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root '.vouchfx-src'))) 'Compose candidate mode must not bootstrap source.'
    $passed++

    $root = New-Case 'default image pins unchanged'
    $null = New-Sample $root 'app' -App
    $result = Invoke-Case $root 'app' 0
    Assert-True ($result.Calls[0] -like 'docker build *' -and -not $result.Calls[0].Contains('DOTNET_SDK_IMAGE=') -and -not $result.Calls[0].Contains('DOTNET_RUNTIME_IMAGE=')) 'The default image build must not gain runtime override arguments.'
    $passed++

    $pins = ConvertFrom-StringData -StringData ([System.IO.File]::ReadAllText(
        (Join-Path (Split-Path -Parent $source) 'dotnet-images.properties')))
    Assert-True ($pins.Count -eq 6) 'Exactly one SDK/runtime image pair is required for each supported major.'
    foreach ($version in @('9.0', '10.0')) {
        $key = $version.Replace('.', '_')
        Assert-True ($pins["sdk_$key"] -match "^mcr.microsoft.com/dotnet/sdk:$([regex]::Escape($version))@sha256:[a-f0-9]{64}$") 'Each selected SDK must use an immutable official image of the requested major.'
        Assert-True ($pins["runtime_$key"] -match "^mcr.microsoft.com/dotnet/aspnet:$([regex]::Escape($version))@sha256:[a-f0-9]{64}$") 'Each selected runtime must use an immutable official image of the requested major.'
        $root = New-Case "selected dotnet $version"
        $null = New-Sample $root 'app' -App
        $env:VOUCHFX_SAMPLE_DOTNET_VERSION = $version
        $result = Invoke-Case $root 'app' 0
        Assert-True ($result.Calls.Count -eq 2 -and $result.Calls[0].Contains("DOTNET_SDK_IMAGE=$($pins["sdk_$key"])") -and $result.Calls[0].Contains("DOTNET_RUNTIME_IMAGE=$($pins["runtime_$key"])")) 'The native image build must receive the shared pinned image pair.'
        $passed++
    }
    $dockerfile = [System.IO.File]::ReadAllText((Join-Path (Split-Path -Parent (Split-Path -Parent $source)) 'samples/orders-dotnet/app/Dockerfile'))
    Assert-True ($dockerfile.Contains("ARG DOTNET_SDK_IMAGE=$($pins['sdk_8_0'])") -and $dockerfile.Contains("ARG DOTNET_RUNTIME_IMAGE=$($pins['runtime_8_0'])")) 'The optional .NET 8 selection must match both unchanged Dockerfile defaults.'

    $root = New-Case 'invalid dotnet version refused'
    $null = New-Sample $root 'app' -App
    $env:VOUCHFX_SAMPLE_DOTNET_VERSION = '11.0'
    $result = Invoke-Case $root 'app' 1
    Assert-True ($result.Calls.Count -eq 0) 'An unsupported runtime selection must stop before any native command.'
    $passed++

    $root = New-Case 'migration image runtime'
    $env:VOUCHFX_SAMPLE_DOTNET_VERSION = '10.0'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'samples/orders-dotnet/app')
    foreach ($name in @('from-postman', 'from-xunit', 'from-specflow')) {
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $root "migrations/$name/ported")
    }
    $console = @(& $shell -NoProfile -File (Join-Path $root 'scripts/run-migrations.ps1') 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) "The migration runner failed: $($console -join ' ')"
    $calls = [System.IO.File]::ReadAllLines($env:VOUCHFX_SAMPLES_TEST_LOG)
    Assert-True ($calls.Count -eq 4 -and $calls[0].Contains("DOTNET_SDK_IMAGE=$($pins['sdk_10_0'])") -and $calls[0].Contains("DOTNET_RUNTIME_IMAGE=$($pins['runtime_10_0'])")) 'Migrations must use the same selected image pair as normal samples.'
    $passed++

    $root = New-Case 'bootstrap preserves pin and enables runtime roll forward'
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $source) 'bootstrap.ps1') -Destination (Join-Path $root 'scripts/bootstrap.ps1') -Force
    $sourceRoot = Join-Path $root '.vouchfx-src'
    git -C $sourceRoot init -q
    Assert-True ($LASTEXITCODE -eq 0) 'Could not initialise the isolated source fixture.'
    git -C $sourceRoot add .
    git -C $sourceRoot -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture
    Assert-True ($LASTEXITCODE -eq 0) 'Could not commit the isolated source fixture.'
    $pin = git -C $sourceRoot rev-parse HEAD
    Write-File (Join-Path $root 'ENGINE_PIN') $pin.Trim()
    $console = @(& $shell -NoProfile -File (Join-Path $root 'scripts/bootstrap.ps1') 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) "Bootstrap failed: $($console -join ' ')"
    $calls = [System.IO.File]::ReadAllLines($env:VOUCHFX_SAMPLES_TEST_LOG)
    Assert-True ($calls.Count -eq 3 -and $calls[2] -like 'dotnet build *-c Release -p:RollForward=Major') 'Bootstrap must supply Major roll-forward while building the selected pin.'
    $status = @(git -C $sourceRoot status --porcelain)
    Assert-True ($LASTEXITCODE -eq 0 -and $status.Count -eq 0) 'Bootstrap must not modify the selected source checkout.'
    $passed++

    Write-Host "$passed/26 sample-runner regressions passed."
}
finally {
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name])
    }
    $resolvedScratch = [System.IO.Path]::GetFullPath($scratch)
    if (-not $resolvedScratch.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove scratch path outside TEMP: $resolvedScratch"
    }
    if (Test-Path -LiteralPath $resolvedScratch) {
        Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
    }
}
