# Consuming Community Providers: The Custom Runner Recipe

When a vouchfx suite needs a **Community-tier provider** from the [vouchfx-providers](https://github.com/tomas-rampas/vouchfx-providers) hub, the engine's stock CLI cannot run it — the CLI ships only the 25 frozen Core providers at build time. This page explains the custom-runner pattern, which lets you consume Community providers today by bundling them directly into a thin executable.

## Why a custom runner exists

Providers in vouchfx are **compile-time, source-level plugins** (§13 of the [engine blueprint](https://github.com/tomas-rampas/vouchfx/blob/main/docs/01_Technical_Architecture_and_Engineering_Blueprint.md)). The registry of available step types is frozen when the engine builds, by reflecting over a fixed set of assemblies:

- The stock `vouchfx` CLI hard-codes its 25 Core provider assemblies.
- Community providers are published as independent NuGet packages, unknown to the CLI.
- There is no runtime loader and no dynamic assembly discovery — no way for the CLI to know about a Community provider without rebuilding itself.

This is deliberate: providers are trusted extensions (they compile arbitrary C# for execution) and locking down the registry at build time prevents supply-chain surprises.

**The workaround until a provider-loader feature ships:** build a custom runner — a small C# executable that wraps the engine's public SDK and references the Community providers you need. The [`ledger-jsonrpc` sample](https://github.com/tomas-rampas/vouchfx-samples/tree/main/samples/ledger-jsonrpc) (`samples/ledger-jsonrpc/runner/`) is the reference implementation.

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

(See [Program.cs line 194–201](https://github.com/tomas-rampas/vouchfx-samples/blob/main/samples/ledger-jsonrpc/runner/Program.cs#L194-L201) for the actual ledger-jsonrpc implementation.)

**Key point:** The same assembly set is used everywhere — step discovery, validation, and execution. When you run `--list` (see below), the runner displays only the step kinds these assemblies export.

### Step 2: Discover and parse `.e2e.yaml` files

Your runner needs to find and parse every test suite under a root directory. Failures are recorded as `Inconclusive` verdicts rather than crashing the discovery:

```csharp
static List<ParsedFile> DiscoverAndParse(string root, StepKindRegistry stepKindRegistry)
{
    var fullRoot = Path.GetFullPath(root);
    if (!Directory.Exists(fullRoot))
        throw new DirectoryNotFoundException(
            $"Discovery root '{root}' does not exist (resolved to '{fullRoot}').");

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

(See [Program.cs lines 205–248](https://github.com/tomas-rampas/vouchfx-samples/blob/main/samples/ledger-jsonrpc/runner/Program.cs#L205-L248).)

### Step 3: Execute the suite against the discovered topology

Once scenarios are parsed, hand them to the engine's public `ScenarioRunner.RunSuiteAsync` API:

```csharp
var appHostAssemblyName = Assembly.GetExecutingAssembly().GetName().Name;

var suiteBaseDirectory = Path.GetDirectoryName(parsed[0].Path);

SuiteResult result = await ScenarioRunner.RunSuiteAsync(
    asts,
    names,
    yamlTexts,
    ProviderAssemblies(),  // ← same assembly set as discovery
    appHostAssemblyName,   // ← YOUR executable's assembly name (for DCP metadata)
    Console.Out,
    seedBaseDirectory: suiteBaseDirectory,
    htmlReportPath: htmlPath,
    junitReportPath: junitPath,
    eventsReportPath: null,
    decorate: decorate,
    cancellationToken: CancellationToken.None).ConfigureAwait(false);
```

**Critical:** `appHostAssemblyName` must be the name of YOUR executable's assembly, not the engine's. This is because the Aspire `AppHost.Sdk` embeds DCP binary paths as metadata onto the assembly that carries `<IsAspireHost>true` in its `.csproj` — and that assembly is your custom runner, not the engine library. See the [engine blueprint §4](https://github.com/tomas-rampas/vouchfx/blob/main/docs/01_Technical_Architecture_and_Engineering_Blueprint.md) for details.

(See [Program.cs lines 149–177](https://github.com/tomas-rampas/vouchfx-samples/blob/main/samples/ledger-jsonrpc/runner/Program.cs#L149-L177).)

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

Exit codes `0/1/3/4` match the verdict taxonomy (§12.1 of the engine blueprint). The stock CLI offers opt-out flags (`--fail-on-env-error`, `--fail-on-inconclusive`); a custom runner typically enforces all non-Pass verdicts as failures for CI.

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
   <PackageReference Include="Vouchfx.Community.JsonRpc" Version="1.0.0-alpha.1" />
   ```

5. **Pin provider client libraries** — Npgsql, Confluent.Kafka, etc. as direct PackageReferences so they deploy to the output directory:
   ```xml
   <PackageReference Include="Npgsql" Version="8.0.7" />
   <PackageReference Include="Confluent.Kafka" Version="2.14.2" />
   ```

See the [ledger-jsonrpc LedgerRunner.csproj](https://github.com/tomas-rampas/vouchfx-samples/blob/main/samples/ledger-jsonrpc/runner/LedgerRunner.csproj) for a complete example.

### Semantic versioning and pre-release pins

When your Community provider is in pre-release (e.g. `1.0.0-alpha.1`), pin it exactly:

```xml
<PackageReference Include="Vouchfx.Community.JsonRpc" Version="1.0.0-alpha.1" />
```

The engine enforces the **NU5104 rule** (§13 of the blueprint): when the engine's SDK is pre-release (`1.0.0-alpha.x`), all provider packages referencing it must also be pre-release. This prevents a stable consumer package from accidentally pinning an unstable engine.

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

(See [Program.cs lines 297–309](https://github.com/tomas-rampas/vouchfx-samples/blob/main/samples/ledger-jsonrpc/runner/Program.cs#L297-L309).)

## Relationship to the provider hub

The [vouchfx-providers repository](https://github.com/tomas-rampas/vouchfx-providers) hosts the Community provider index and (soon) will publish a comprehensive "implementing a provider" guide that covers packaging, registry policy, and versioning strategies. This page owns the **runnable code walkthrough** for how to integrate a Community provider into a test suite; the hub owns the provider authoring and publishing contract.

For real-world examples, see:
- [ledger-jsonrpc sample README](https://github.com/tomas-rampas/vouchfx-samples/blob/main/samples/ledger-jsonrpc/README.md) — end-to-end walkthrough of the custom runner
- [LedgerRunner.cs](https://github.com/tomas-rampas/vouchfx-samples/blob/main/samples/ledger-jsonrpc/runner/Program.cs) — the reference implementation
