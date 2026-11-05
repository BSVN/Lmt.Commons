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

- `src/Bsn.Host/Private/Start-BsnWindowsPtyRecording.ps1` embeds a C#
  ConPTY engine compiled via Add-Type. It must stay C# 5 compatible
  (no string interpolation, no `out var`) because Windows PowerShell 5.1
  compiles it, must restore the console input mode in `finally`, and the
  cast writer must emit UTF-8 without BOM with LF line endings.
  `ConvertTo-BsnAsciicast` is the pure, Pester-tested conversion logic -
  extend tests there rather than smoke-testing the native engine.
- `src/Bsn.SystemManagement/scripts/Suspend-Action.ps1` must remain
  fully self-contained (no references to module functions/variables): it is
  executed locally AND shipped as-is to remote machines via
  `Invoke-Command -FilePath`. Duplicating tiny helpers inside it is intended.
  The same self-containment rule applies to `Get-BsnOperatingSystem`, which
  is deliberately duplicated per module instead of cross-imported.
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
