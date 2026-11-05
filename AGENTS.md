# AGENTS.md

Guidance for AI coding agents working in this repository.

## What this is

Monorepo producing the `Bsn.*` PowerShell module family for the PowerShell
Gallery. One repo, many independently-versioned modules (azure-powershell
model). License is GPL-3.0 — do not relicense module code.

## Module layout rules (auto-discovery)

- Any folder `src/<Name>/<Name>.psd1` is automatically picked up by
  `build.ps1` and CI. No registration step; don't add module lists anywhere.
- Tests live **inside** each module: `src/<Module>/tests/*.Tests.ps1`. The
  Package task strips `tests/` before publishing.
- Module version source of truth = `ModuleVersion` in each `.psd1`. The
  gallery-compare logic in the Publish task depends on it.

## Creating modules: Plaster only

New modules are created exclusively with the Plaster template, never by
copying an existing module by hand:

```powershell
./tools/New-BsnModule.ps1 -ModuleName Bsn.Example -CmdletName Get-Example -Description '...'
```

- The template enforces the `Bsn.` prefix and `<Verb>-<Noun>` naming via
  `pattern` attributes in `templates/BsnModule/plasterManifest.xml`.
- **Gotcha:** the Plaster schema attribute is `pattern`, not `validate`.
  Using `validate` fails schema validation with an unhelpful error.
- Template files under `templates/` contain `<%= $PLASTER_PARAM_* %>`
  placeholders, so they are not valid PowerShell and will fail parsing —
  exclude `templates/` from any parse/syntax checks.

## Commands

```powershell
./build.ps1 -Bootstrap                                   # deps: Pester 5.7.1+, PSScriptAnalyzer, Plaster
./build.ps1                                             # Analyze + Test, all modules
./build.ps1 -Task Analyze, Test -ModulesFilter 'Bsn.SystemManagement'   # single module
./build.ps1 -Task Package                                # stages out/modules, zips out/packages
./build.ps1 -Task Publish -ApiKey <key>                  # or $env:PS_GALLERY_KEY
```

- **Quirk when invoking via `pwsh -File`:** `-Task Analyze, Test` splits into
  separate tokens and mis-binds. Use `pwsh -Command "./build.ps1 -Task Analyze, Test"`
  or comma without space. Native console invocation is fine.
- Bootstrap deliberately does **not** pass `-Repository PSGallery` to
  `Install-Module`: on some machines (observed on the maintainer's Windows
  box) that combination fails with "Unable to resolve package source" while
  plain `Install-Module` works. Don't add it back.

## Quality gate (must stay green)

- `Analyze` runs PSScriptAnalyzer at Severity Error+Warning over the whole
  module folder including tests. Any finding fails the build.
- Test fixtures with hardcoded computer names trip
  `PSAvoidUsingComputerNameHardcoded`; suppress per test file with the
  script-level attribute + empty `param()` at the top (see
  `src/Bsn.SystemManagement/tests/Suspend-Computer.Tests.ps1`).
- Analyzer on C#: keep `src/**/*.cs` warning-free for netstandard2.0
  (the only target); `dotnet build` runs as part of every build task and
  fails the pipeline on errors.
- Keep .ps1/.psm1 files ASCII-only (no em-dashes, curly quotes) to avoid
  encoding/BOM analyzer issues.

## Cross-edition compatibility: Windows PowerShell 5.1 AND PowerShell 7

Both editions must parse, analyze clean, and pass tests. Real pitfalls hit
before:

- Under `Set-StrictMode`, `$PSVersionTable.Platform` / `.OS` throw on 5.1
  (keys don't exist). Guard with `$PSVersionTable.ContainsKey('Platform')`
  — see `Get-BsnOperatingSystem` for the pattern.
- No piping directly out of a `foreach` statement (`@(foreach ... } | x)`
  is a 5.1 parse error) — assign first, then pipe.
- `Copy-Item -Path dir\* -Destination <new-path>` requires the destination
  directory to exist, otherwise the first copied file creates a leaf and
  containers fail with "Container cannot be copied onto existing leaf item".
- Pester: config lives under `New-PesterConfiguration`; `Run.TestSuiteName`
  does not exist in 5.9.x (don't use it).

## Module-specific constraints

- C# interop code lives in real .NET projects, one per module
  (`src/<Module>/<Module>.csproj`, netstandard2.0, output to
  `src/<Module>/lib/`), loaded via `RequiredAssemblies` in the manifest.
  `build.ps1` compiles every csproj with `dotnet build` before any task
  runs; `lib/` and `obj/` are gitignored build outputs. Do not embed C# in
  here-strings inside .ps1 files.
- Shared helpers are factored into `src/Bsn.Common` (required by the other
  modules via RequiredModules, the Az/VMware-style dependency chain):
  `Get-BsnOperatingSystem` returns the native PowerShell `BsnOperatingSystem`
  enum using the native `RuntimeInformation.IsOSPlatform` API with an
  `$env:OS` fallback for old Windows PowerShell. Do not duplicate it in
  consumer modules; module loaders prefer the repo sibling during development
  and fall back to the gallery copy.
- PowerShell keyword types (`enum`/`class`) have empirically verified rules
  in this repo (bisected on PS 5.1 and PS 7 - see CHANGELOG):
  - Define the type in the same compilation unit (file) as code that uses
    it bare: `Bsn.Common.psm1` defines the enum and its function together.
  - Consumer files that need the type must start with
    `using module Bsn.Common` and then use the bare name.
  - NEVER put a bare keyword-type literal inside an attribute in a
    dot-sourced file (e.g. `[OutputType([BsnOperatingSystem])]`):
    attributes bind at compile time, cannot resolve dynamic enums, and the
    binding failure poisons the first call of that function. This is the
    exact bug that originally forced a C# enum; use the string form
    `[OutputType('BsnOperatingSystem')]` instead.
  - Bare literals in function bodies DO work cross-module once the
    defining module is loaded - the consumer module loaders import
    Bsn.Common before dot-sourcing function files, so this always holds.
  - Enum PARAM TYPE CONSTRAINTS (e.g. `[BsnOperatingSystem]$Platform`)
    work for real calls but break Pester's `Mock` (CommandMetadata
    generation cannot resolve cross-module dynamic enums) - type such
    parameters as [string] with a ValidateSet instead.
  - Avoid `using module Bsn.Common` in consumer files: it resolves the
    module name through PSModulePath at parse time and breaks when the
    module was imported by path (dev flows).
- The Bsn.Host ConPTY engine (`src/Bsn.Host/src/PtyRecorder.cs`) must
  restore the console input mode in `finally`, close the PTY-side pipe
  handles after CreatePseudoConsole (EchoCon pattern), and emit cast files
  as UTF-8 without BOM with LF line endings. Cast files support asciicast
  v2 (absolute event times) and v3 (intervals since the previous event,
  millisecond precision, trailing 'x' exit event) - keep both writers in
  sync with ConvertTo-BsnAsciicast. `ConvertTo-BsnAsciicast` and
  `Get-BsnCastTimeline` are the pure, Pester-tested conversion/parsing
  logic - extend tests there rather than smoke-testing the native engine.
- `src/Bsn.SystemManagement/scripts/Suspend-Action.ps1` must remain fully
  self-contained (it is shipped alone to remote machines via
  `Invoke-Command -FilePath`, which cannot carry the module's DLL): its
  small inline P/Invoke copy of SetSuspendState is the one justified
  exception to the no-embedded-C# rule. Locally, Windows suspend calls the
  compiled `Bsn.SystemManagement.Interop.PowerProf` assembly instead.
- Private helper naming: `<ApprovedVerb>-Bsn<Noun>` (e.g. `Get-BsnOperatingSystem`).
- Every public cmdlet ships three doc artifacts: comment-based help in the
  function (source of truth, renders via Get-Help), `en-US/about_*.help.txt`,
  and `docs/en-US/<Cmdlet>.md`. Update all three together.

## CI / publishing

- CI (`.github/workflows/CI.yml`) runs Analyze+Test on windows/ubuntu/macos
  for every push/PR. Never make tests that actually suspend/sleep a machine —
  all suspend-path tests are mocked.
- Publishing (`.github/workflows/Publish.yml`) triggers on a **published
  GitHub Release**. It runs the full gate, then publishes every module whose
  manifest version is newer than the gallery version (idempotent, safe to
  re-run). Manual dispatch supports `dry_run`.
- Gallery auth = `PS_GALLERY_KEY` repo secret (already configured). Never
  put the API key in any repo file, workflow, or commit.

## Git etiquette

Do not push to origin unless the user explicitly asks in the session.
Commit locally by default.
