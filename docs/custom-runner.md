# Consuming Community Providers: The Custom Runner Recipe

When a vouchfx suite needs a **Community-tier provider** from the [vouchfx-providers hub](https://providers.vouchfx.io/) (see its [consuming-a-provider guide](https://providers.vouchfx.io/docs/consuming-a-provider.html)), there are two ways to run it. From Core 1.2.0 the stock CLI can load trusted external providers at startup: `vouchfx providers install rpc.json-rpc` installs a published provider under `~/.vouchfx/providers`, and `--providers <dir>` loads a prepared directory (see the engine's [external providers guide](https://vouchfx.io/external-providers/)). This page explains the other way, the custom-runner pattern, which bundles Community providers directly into a thin executable at build time.

## Why a custom runner exists

Providers in vouchfx are **compile-time, source-level plugins** (§13 of the [engine blueprint](https://vouchfx.io/01_Technical_Architecture_and_Engineering_Blueprint/)): they bind typed models and emit C#. The stock CLI's registry of step types is frozen before it discovers any suite:

- The stock `vouchfx` CLI bundles its 25 Core provider assemblies.
- Community providers are published as independent NuGet packages, not bundled with the CLI.
- Before Core 1.2.0 there was no runtime loader, so the CLI could not use a Community provider without being rebuilt. From 1.2.0 it admits trusted provider assemblies from `--providers`, `VOUCHFX_PROVIDERS` and `~/.vouchfx/providers` before freezing the merged registry.

Either way, providers are trusted extensions: they compile arbitrary C# for execution, and neither loading nor installing one sandboxes or endorses it.

**A custom runner fixes the provider set at build time:** it is a small C# executable that wraps the engine's public SDK and references the Community providers you need, so their versions are locked with the rest of the build and no provider directory has to be configured where it runs. It was the only way to consume a Community provider before Core 1.2.0. The [`ledger-jsonrpc` sample](https://github.com/tomas-rampas/vouchfx-samples/tree/main/samples/ledger-jsonrpc) (`samples/ledger-jsonrpc/runner/`) is the reference implementation.

## The essential path (with code examples)

### Step 1: Build and freeze the provider registry

The core of a custom runner is building the **frozen registry** that the engine uses to validate and compile steps. This happens once at startup:

```csharp
StepKindRegistry registry = StepKindRegistry.BuildAndFreeze(ProviderAssemblies());
```

The `ProviderAssemblies()` helper returns an `Assembly[]` — typically 4–5 Core providers plus your Community provider(s):

```csharp
static Assembly[] ProviderAssemblies() =>
[
    typeof(DbAssertPostgresProvider).Assembly,    // Core: db-assert.postgres
    typeof(MqPublishKafkaProvider).Assembly,      // Core: mq-publish.kafka
    typeof(MqExpectKafkaProvider).Assembly,       // Core: mq-expect.kafka
    typeof(ScriptCsharpProvider).Assembly,        // Core: script.csharp
    typeof(JsonRpcProvider).Assembly,             // Community: rpc.json-rpc
];
```

(See [Program.cs lines 194–201](https://github.com/tomas-rampas/vouchfx-samples/blob/main/samples/ledger-jsonrpc/runner/Program.cs#L194-L201) — abridged and annotated for readability.)

**Key point:** The same assembly set is used everywhere — step discovery, validation, and execution. When you run `--list` (see below), the runner displays only the step kinds these assemblies export.

### Step 2: Discover and parse `.e2e.yaml` files

Your runner needs to find and parse every test suite under a root directory. Failures are recorded as `Inconclusive` verdicts rather than crashing the discovery (abridged and annotated for readability):

```csharp
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

static ParsedFile ParseFile(string absolutePath, StepKindRegistry stepKindRegistry)
{
    string yamlText;
    try
    {
        yamlText = File.ReadAllText(absolutePath);
    }
    catch (IOException ex)
    {
        return new ParsedFile(absolutePath, string.Empty, null,
            $"Could not read file: {ex.Message}");
    }

    try
    {
        var doc = YamlDocumentParser.Parse(yamlText);
        var ast = AstBuilder.Build(doc, stepKindRegistry);
        return new ParsedFile(absolutePath, yamlText, ast, null);
    }
    catch (Exception ex)
    {
        return new ParsedFile(absolutePath, yamlText, null, 
            $"Parse / AST error: {ex.Message}");
    }
}
```

**Parse failures map to `Inconclusive`** verdicts (§12.1 verdict taxonomy). A malformed YAML file in the suite directory causes that scenario to be recorded as `Inconclusive` (authoring error, never ran), not a crash or silent skip.

(See [Program.cs lines 205–248](https://github.com/tomas-rampas/vouchfx-samples/blob/main/samples/ledger-jsonrpc/runner/Program.cs#L205-L248) — abridged and annotated for readability.)

### Step 3: Execute the suite against the discovered topology

Once scenarios are parsed, hand them to the engine's public `ScenarioRunner.RunSuiteAsync` API (abridged and annotated for readability):

```csharp
var appHostAssemblyName = Assembly.GetExecutingAssembly().GetName().Name;

var suiteBaseDirectory = Path.GetDirectoryName(parsed[0].Path);

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
```

**Critical:** `appHostAssemblyName` must be the name of YOUR executable's assembly, not the engine's. This is because the Aspire `AppHost.Sdk` embeds DCP binary paths as metadata onto the assembly that carries `<IsAspireHost>true` in its `.csproj` — and that assembly is your custom runner, not the engine library. See the [engine blueprint §4](https://vouchfx.io/01_Technical_Architecture_and_Engineering_Blueprint/) for details.

(See [Program.cs lines 149–177](https://github.com/tomas-rampas/vouchfx-samples/blob/main/samples/ledger-jsonrpc/runner/Program.cs#L149-L177) — abridged and annotated for readability.)

### Step 4: Aggregate verdicts and map to exit codes

Fold discovery parse-failures into the suite verdict using the frozen taxonomy precedence (`EnvironmentError > Fail > Inconclusive > Pass`), then map to a process exit code:

```csharp
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

static int ExitCodeFor(Verdict verdict) => verdict switch
{
    Verdict.Fail => 1,
    Verdict.EnvironmentError => 3,
    Verdict.Inconclusive => 4,
    _ => 0, // Pass
};
```

Exit codes `0/1/3/4` match the verdict taxonomy (§12.1 of the engine blueprint). The stock CLI treats `EnvironmentError` and `Inconclusive` as success (exit `0`) by default; the flags `--fail-on-env-error` and `--fail-on-inconclusive` are opt-in escalations that make these verdicts exit `3` and `4` respectively. A custom runner typically enforces all non-Pass verdicts as failures for CI (matching the behaviour of the CLI with both flags enabled), as this repository's samples do.

(See [Program.cs lines 273–295](https://github.com/tomas-rampas/vouchfx-samples/blob/main/samples/ledger-jsonrpc/runner/Program.cs#L273-L295).)

## Project file setup

Your `.csproj` must:

1. **Reference the Aspire.AppHost.Sdk** — this embeds DCP binary paths as metadata:
   ```xml
   <Sdk Name="Aspire.AppHost.Sdk" Version="13.4.2" />
   ```

2. **Mark as an Aspire host** — so the build targets embed DCP metadata onto your assembly:
   ```xml
   <IsAspireHost>true</IsAspireHost>
   ```

3. **Reference the engine's SDK + runtime + core providers via ProjectReference** — source projects from `.vouchfx-src/`, pinned via `ENGINE_PIN`:
   ```xml
   <ProjectReference Include="..\..\..\.vouchfx-src\src\Engine\Vouchfx.Engine.Runtime\Vouchfx.Engine.Runtime.csproj" 
                     IsAspireProjectResource="false" />
   <ProjectReference Include="..\..\..\.vouchfx-src\src\Sdk\Vouchfx.Sdk\Vouchfx.Sdk.csproj" 
                     IsAspireProjectResource="false" />
   ```

4. **Reference your Community provider package** — exactly as you would any NuGet dependency:
   ```xml
   <PackageReference Include="Vouchfx.Community.JsonRpc" Version="[1.0.0]" />
   ```

5. **Pin provider client libraries** — Npgsql, Confluent.Kafka, etc. as direct PackageReferences so they deploy to the output directory:
   ```xml
   <PackageReference Include="Npgsql" Version="8.0.7" />
   <PackageReference Include="Confluent.Kafka" Version="2.14.2" />
   ```

See the [ledger-jsonrpc LedgerRunner.csproj](https://github.com/tomas-rampas/vouchfx-samples/blob/main/samples/ledger-jsonrpc/runner/LedgerRunner.csproj) for a complete example.

### Semantic versioning and exact package pins

Pin the stable provider version used by the runner (`1.0.0`) exactly. If you choose a prerelease, pin its complete prerelease version instead:

```xml
<PackageReference Include="Vouchfx.Community.JsonRpc" Version="[1.0.0]" />
```

**NU5104** is NuGet's pack warning: a stable (released) package must not depend on pre-release packages. When the engine's SDK is pre-release (`1.0.0-alpha.x`), any provider package referencing it must also be pre-release (or pack will warn). This prevents downstream consumers from accidentally landing on an unstable engine.

## Reporting: identical to the stock CLI

Your runner produces the exact same report artefacts as the stock `vouchfx` engine CLI:

- **JUnit XML** — via `junitReportPath` parameter to `ScenarioRunner.RunSuiteAsync`
- **Interactive HTML report** — via `htmlReportPath` parameter
- **Event stream** (optional) — via `eventsReportPath` parameter

The same rendering logic runs whether reports are generated by the CLI or your custom runner.

## The `--list` command: drift-proof step discovery

Include a `--list` mode that dumps every registered step kind without starting topology or Docker:

```csharp
if (listOnly)
{
    PrintRegistry(registry, Console.Out);
    return 0;
}

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
```

This is a **registry smoke test** safe to run without Docker. The same assembly set feeds `--list` and the actual run, so the list can never drift from what a suite execution will see.

(See [Program.cs lines 109–113](https://github.com/tomas-rampas/vouchfx-samples/blob/main/samples/ledger-jsonrpc/runner/Program.cs#L109-L113) for the `if (listOnly)` branch and [lines 297–309](https://github.com/tomas-rampas/vouchfx-samples/blob/main/samples/ledger-jsonrpc/runner/Program.cs#L297-L309) for the `PrintRegistry` implementation.)

## Relationship to the provider hub

The [vouchfx-providers hub](https://providers.vouchfx.io/) hosts the Community provider index and publishes comprehensive guides on consuming and implementing providers. This page owns the **runnable code walkthrough** for how to integrate a Community provider into a test suite; the hub owns the provider authoring and publishing contract.

For real-world examples, see:
- [ledger-jsonrpc sample README](https://github.com/tomas-rampas/vouchfx-samples/blob/main/samples/ledger-jsonrpc/README.md) — end-to-end walkthrough of the custom runner
- [Program.cs](https://github.com/tomas-rampas/vouchfx-samples/blob/main/samples/ledger-jsonrpc/runner/Program.cs) — the reference implementation
