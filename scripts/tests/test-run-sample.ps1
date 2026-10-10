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
    'VOUCHFX_SAMPLES_TEST_CLI_EXIT'
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
    param([string]$Name)
    $root = Join-Path $scratch $Name
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'scripts')
    Copy-Item -LiteralPath $source -Destination (Join-Path $root 'scripts/run-sample.ps1')
    Write-File (Join-Path $root '.vouchfx-src/src/Cli/Vouchfx.Cli/Vouchfx.Cli.csproj') '<Project />'
    $env:VOUCHFX_SAMPLES_TEST_LOG = Join-Path $root 'calls.log'
    $env:VOUCHFX_SAMPLES_TEST_EXPECT_FIXTURE = ''
    $env:VOUCHFX_SAMPLES_TEST_DOCKER_EXIT = '0'
    $env:VOUCHFX_SAMPLES_TEST_RUNNER_BUILD_EXIT = '0'
    $env:VOUCHFX_SAMPLES_TEST_CLI_EXIT = '0'
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
        & chmod +x (Join-Path $bin 'docker') (Join-Path $bin 'dotnet')
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

    Write-Host "$passed/9 sample-runner regressions passed."
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
