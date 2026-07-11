// LedgerRunner — a custom vouchfx runner, and the first real demonstration of
// COMMUNITY-provider consumption in this samples repo.
//
// Every other sample here runs its suite through the shared `vouchfx` engine CLI
// (scripts/run-sample.sh auto-detects it), because the engine CLI only ships the Core provider
// catalogue. The ledger-jsonrpc suite also exercises rpc.json-rpc — a Community-tier
// provider published as the Vouchfx.Community.JsonRpc NuGet package
// (github.com/tomas-rampas/vouchfx-providers) — which the stock CLI does not know
// about. Providers are compile-time, source-level plugins (no runtime loader, no
// dynamic assembly loading — see the engine's CLAUDE.md §"Provider model"), so
// consuming one that the CLI wasn't built with means building a small executable
// of our own that references it directly. That executable is this project.
//
// This file deliberately mirrors, as closely as a standalone project can, the
// ESSENTIAL path .vouchfx-src/src/Cli/Vouchfx.Cli/RunCommand.cs drives:
//   1. Build a frozen provider registry (StepKindRegistry.BuildAndFreeze) over the
//      four Core providers this suite needs PLUS the community rpc.json-rpc
//      provider (RunCommand's ProviderRegistryFactory.BuildCoreRegistry, widened).
//   2. Discover *.e2e.yaml files under the given directory, parse each with
//      YamlDocumentParser.Parse -> AstBuilder.Build (RunCommand's
//      ScenarioDiscovery.ParseFile), capturing a parse/AST failure as an
//      Inconclusive scenario rather than crashing discovery of the rest of the
//      suite (§12.1 — an authoring error, the scenario never ran).
//   3. Hand every scenario that DID parse to ScenarioRunner.RunSuiteAsync, which
//      performs its OWN pre-compile JSON Schema validation per scenario
//      (DocumentValidator.Validate, called internally) — RunCommand never runs a
//      SEPARATE schema-validation pass before calling it, so neither does this
//      runner; skipping that would skip a validation stage the CLI does perform.
//   4. Fold discovery failures into the suite verdict (EnvironmentError > Fail >
//      Inconclusive > Pass — RunCommand.AggregateVerdict / ScenarioRunner.Elevate,
//      both `internal` to their assemblies and so reimplemented here verbatim).
//   5. Map the final verdict to a process exit code. Unlike the CLI (which gates
//      --fail-on-env-error / --fail-on-inconclusive behind opt-in flags), this
//      runner is ALWAYS strict — matching scripts/run-sample.sh, which passes
//      both flags unconditionally for every sample it drives.
//
// appHostAssemblyName: THIS executable's own assembly name ("LedgerRunner"), not
// "vouchfx" — DCP metadata (dcpclipath / aspiredashboardpath) is embedded by the
// Aspire.AppHost.Sdk onto the assembly that actually carries <IsAspireHost>true
// (see LedgerRunner.csproj), which is this project, not the engine CLI.

using System.Reflection;
using Vouchfx.Community.JsonRpc;
using Vouchfx.Engine.Abstractions;
using Vouchfx.Engine.Authoring;
using Vouchfx.Engine.Authoring.Ast;
using Vouchfx.Engine.Runtime;
using Vouchfx.Sdk;
using Vouchfx.Steps.DbAssert.Postgres;
using Vouchfx.Steps.MqExpect.Kafka;
using Vouchfx.Steps.MqPublish.Kafka;
using Vouchfx.Steps.Script.Csharp;

// ── 1. Parse the tiny CLI surface: <tests-dir> [--junit <path>] [--html <path>] | --list ──
if (args.Length == 0 || args is ["-h" or "--help"])
{
    PrintUsage();
    return args.Length == 0 ? 2 : 0;
}

var listOnly = false;
string? testsDir = null;
string? junitPath = null;
string? htmlPath = null;

for (var i = 0; i < args.Length; i++)
{
    switch (args[i])
    {
        case "--list":
            listOnly = true;
            continue;
        case "--junit" or "--html" when i + 1 >= args.Length:
            Console.Error.WriteLine($"'{args[i]}' requires a path argument.");
            return 2;
        case "--junit":
            junitPath = args[++i];
            continue;
        case "--html":
            htmlPath = args[++i];
            continue;
        default:
            if (args[i].StartsWith("--", StringComparison.Ordinal))
            {
                Console.Error.WriteLine($"Unrecognised option '{args[i]}'.");
                PrintUsage();
                return 2;
            }

            testsDir ??= args[i];
            continue;
    }
}

if (!listOnly && testsDir is null)
{
    Console.Error.WriteLine("Missing required <tests-dir> argument.");
    PrintUsage();
    return 2;
}

// ── 2. Build + freeze the provider registry: 4 Core providers + rpc.json-rpc ──
// Kept as a permanent runner feature (not a one-off diagnostic): the SAME
// assembly set is passed to RunSuiteAsync below, which rebuilds its own frozen
// registry internally from it — so --list can never drift from what a real run
// actually registers.
StepKindRegistry registry = StepKindRegistry.BuildAndFreeze(ProviderAssemblies());

if (listOnly)
{
    PrintRegistry(registry, Console.Out);
    return 0;
}

// ── 3. Discover + parse *.e2e.yaml under <tests-dir> ──────────────────────────
List<ParsedFile> discovered;
try
{
    discovered = DiscoverAndParse(testsDir!, registry);
}
catch (DirectoryNotFoundException ex)
{
    Console.Error.WriteLine(ex.Message);
    return 2;
}

if (discovered.Count == 0)
{
    Console.WriteLine($"No *.e2e.yaml scenarios found under '{testsDir}'.");
    return 0; // Nothing ran; nothing failed — success per §12.1.
}

var parsed = discovered.Where(f => f.Ast is not null).ToList();
var failures = discovered.Where(f => f.Ast is null).ToList();

foreach (var failure in failures)
{
    Console.WriteLine($"{failure.Path}: {failure.Error} (Inconclusive)");
}

// ── 4. Run every scenario that parsed against one shared topology ─────────────
var suiteVerdict = Verdict.Pass;
if (parsed.Count > 0)
{
    var asts = parsed.Select(p => p.Ast!).ToList();
    var names = parsed.Select(ScenarioName).ToList();
    var yamlTexts = parsed.Select(p => p.YamlText).ToList();

    var appHostAssemblyName = Assembly.GetExecutingAssembly().GetName().Name;

    // Base directory for relative paths in step/seed fields (e.g. script.csharp's
    // `file`, environment.seed fixtures) — the first scenario's own directory, NOT
    // Directory.GetCurrentDirectory() (which `dotnet run --project ../runner` sets
    // to the runner's OWN project directory — see the file-header GOTCHA note in
    // ledger.e2e.yaml). Mirrors Vouchfx.Cli's RunCommand.cs fix for the identical
    // gap in the stock CLI. All scenarios in a suite share one `environment` block
    // (ScenarioRunner enforces this), so one base directory is correct here too.
    var suiteBaseDirectory = Path.GetDirectoryName(parsed[0].Path);

    // Same interactive-TTY + NO_COLOR gate the CLI computes before rendering
    // (S10-G-03a) — decoration is purely additive, never load-bearing.
    var decorate = !Console.IsOutputRedirected
        && string.IsNullOrEmpty(Environment.GetEnvironmentVariable("NO_COLOR"));

    SuiteResult result = await ScenarioRunner.RunSuiteAsync(
        asts,
        names,
        yamlTexts,
        ProviderAssemblies(),
        appHostAssemblyName,
        Console.Out,
        seedBaseDirectory: suiteBaseDirectory,
        htmlReportPath: htmlPath,
        junitReportPath: junitPath,
        eventsReportPath: null,
        decorate: decorate,
        cancellationToken: CancellationToken.None).ConfigureAwait(false);

    suiteVerdict = result.Verdict;
}

// Discovery parse-failures elevate the suite verdict to at least Inconclusive —
// they never ran, so they can never count as a Pass.
var aggregate = failures.Count > 0 ? Elevate(suiteVerdict, Verdict.Inconclusive) : suiteVerdict;

return ExitCodeFor(aggregate);

// ── Local functions ─────────────────────────────────────────────────────────

// The single point of truth for which providers THIS runner bundles: the four
// Core providers the ledger suite needs, plus the community rpc.json-rpc
// provider. Mirrors Vouchfx.Cli's ProviderRegistryFactory.CoreProviderAssemblies,
// widened by one community assembly.
static Assembly[] ProviderAssemblies() =>
[
    typeof(DbAssertPostgresProvider).Assembly, // db-assert.postgres
    typeof(MqPublishKafkaProvider).Assembly,   // mq-publish.kafka
    typeof(MqExpectKafkaProvider).Assembly,    // mq-expect.kafka
    typeof(ScriptCsharpProvider).Assembly,     // script.csharp
    typeof(JsonRpcProvider).Assembly,          // rpc.json-rpc (COMMUNITY)
];

// Mirrors Vouchfx.Cli's (internal) ScenarioDiscovery.Discover: recursively finds
// every *.e2e.yaml file, in a stable ordinal path order, and parses each one.
static List<ParsedFile> DiscoverAndParse(string root, StepKindRegistry stepKindRegistry)
{
    var fullRoot = Path.GetFullPath(root);
    if (!Directory.Exists(fullRoot))
    {
        throw new DirectoryNotFoundException(
            $"Discovery root '{root}' does not exist (resolved to '{fullRoot}').");
    }

    var files = Directory
        .EnumerateFiles(fullRoot, "*.e2e.yaml", SearchOption.AllDirectories)
        .Select(Path.GetFullPath)
        .OrderBy(p => p, StringComparer.Ordinal)
        .ToList();

    return files.Select(path => ParseFile(path, stepKindRegistry)).ToList();
}

// Mirrors Vouchfx.Cli's (internal) ScenarioDiscovery.ParseFile: a parse / AST-build
// failure is captured on the record rather than thrown, so one malformed file
// cannot crash discovery of the rest of the suite.
static ParsedFile ParseFile(string absolutePath, StepKindRegistry stepKindRegistry)
{
    string yamlText;
    try
    {
        yamlText = File.ReadAllText(absolutePath);
    }
    catch (IOException ex)
    {
        return new ParsedFile(absolutePath, string.Empty, null, $"Could not read file: {ex.Message}");
    }

    try
    {
        var doc = YamlDocumentParser.Parse(yamlText);
        var ast = AstBuilder.Build(doc, stepKindRegistry);
        return new ParsedFile(absolutePath, yamlText, ast, null);
    }
    catch (Exception ex)
    {
        return new ParsedFile(absolutePath, yamlText, null, $"Parse / AST error: {ex.Message}");
    }
}

// Mirrors Vouchfx.Cli's (internal) RunCommand.ScenarioName: metadata.name when
// present, else the file name with the .e2e.yaml suffix stripped.
static string ScenarioName(ParsedFile file)
{
    var metaName = file.Ast?.Metadata?.Name;
    if (!string.IsNullOrWhiteSpace(metaName))
    {
        return metaName;
    }

    var fileName = Path.GetFileName(file.Path);
    const string suffix = ".e2e.yaml";
    return fileName.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)
        ? fileName[..^suffix.Length]
        : fileName;
}

// Mirrors Vouchfx.Engine.Runtime's (internal) ScenarioRunner.Elevate /
// VerdictPrecedence verbatim: EnvironmentError > Fail > Inconclusive > Pass.
// Neither is reachable from here (InternalsVisibleTo on that assembly only
// names "vouchfx", the engine CLI's own assembly), so the two four-line helpers
// are reimplemented rather than exposed — the values are frozen by the v1
// verdict taxonomy (§12.1), so duplication cannot drift silently.
static Verdict Elevate(Verdict current, Verdict next) =>
    VerdictPrecedence(next) > VerdictPrecedence(current) ? next : current;

static int VerdictPrecedence(Verdict v) => v switch
{
    Verdict.Pass => 0,
    Verdict.Inconclusive => 1,
    Verdict.Fail => 2,
    Verdict.EnvironmentError => 3,
    _ => 0,
};

// Always-strict verdict -> exit code mapping (§12.1), matching
// scripts/run-sample.sh's --fail-on-env-error / --fail-on-inconclusive policy —
// unlike the engine CLI, this runner has no opt-out: every sample run here is a
// CI gate, so every non-Pass verdict must be visible in the exit code.
static int ExitCodeFor(Verdict verdict) => verdict switch
{
    Verdict.Fail => 1,
    Verdict.EnvironmentError => 3,
    Verdict.Inconclusive => 4,
    _ => 0, // Pass
};

static void PrintRegistry(StepKindRegistry stepKindRegistry, TextWriter output)
{
    output.WriteLine($"Registered step kinds ({stepKindRegistry.All.Count}):");
    foreach (var provider in stepKindRegistry.All
                 .OrderBy(p => p.Kind.Family, StringComparer.Ordinal)
                 .ThenBy(p => p.Kind.Provider, StringComparer.Ordinal))
    {
        var kind = $"{provider.Kind.Family}.{provider.Kind.Provider}";
        output.WriteLine(
            $"  {kind,-24} v{provider.Metadata.Version}" +
            $"  (min engine {provider.Metadata.MinEngineVersion}, {provider.Metadata.License})");
    }
}

static void PrintUsage()
{
    Console.Error.WriteLine("""
        LedgerRunner — a custom vouchfx runner for the ledger-jsonrpc sample, wiring
        the community rpc.json-rpc provider (Vouchfx.Community.JsonRpc) alongside
        four Core providers (db-assert.postgres, mq-publish.kafka, mq-expect.kafka,
        script.csharp — Core kinds the stock CLI also ships, bundled here as source-built copies) plus `rpc.json-rpc`, which the stock CLI does not know about.

        Usage:
          LedgerRunner <tests-dir> [--junit <path>] [--html <path>]
          LedgerRunner --list

        Arguments / options:
          <tests-dir>      Directory to search for *.e2e.yaml scenarios (recursively).
          --junit <path>   Write a JUnit XML results file to <path>.
          --html <path>    Write a self-contained HTML report to <path>.
          --list           Print every registered step kind (community + core) and
                            exit. Discovers no scenarios and starts no topology —
                            a registry smoke test safe to run without Docker.

        Exit codes (always strict — no --fail-on-* opt-outs, unlike the engine CLI):
          0  Pass              2  Usage error
          1  Fail               3  Environment error
          4  Inconclusive
        """);
}

// A single *.e2e.yaml file under the discovery root, with its raw text and (when
// it parses) its built ScenarioAst. Mirrors Vouchfx.Cli's (internal)
// DiscoveredScenario record.
internal sealed record ParsedFile(string Path, string YamlText, ScenarioAst? Ast, string? Error);
