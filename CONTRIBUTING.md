# Contributing to Lmt.Commons

Thank you for your interest in contributing to the **Bsn.* PowerShell module
family**! This document explains how to set up, build, test, and submit
changes. It is written for human contributors; AI coding agents should
additionally follow the detailed guidance in [AGENTS.md](AGENTS.md).

## Repository overview

This is a monorepo producing the `Bsn.*` PowerShell module family published to
the [PowerShell Gallery](https://www.powershellgallery.com/) (one repo, many
independently-versioned modules, azure-powershell model). Each module lives in
`src/<Name>/` with its manifest `src/<Name>/<Name>.psd1` and its tests inside
`src/<Name>/tests/*.Tests.ps1`. New modules are created **only** with the
Plaster template:

```powershell
./tools/New-BsnModule.ps1 -ModuleName Bsn.Example -CmdletName Get-Example -Description '...'
```

## Prerequisites

- Windows PowerShell 5.1 **and** PowerShell 7 (both editions must parse,
  analyze clean, and pass tests)
- .NET SDK (for the C# interop projects, netstandard2.0)
- Build dependencies (Pester, PSScriptAnalyzer, Plaster):

```powershell
./build.ps1 -Bootstrap
```

## Build and test

```powershell
./build.ps1                                          # Analyze + Test, all modules
./build.ps1 -Task Analyze, Test -ModulesFilter 'Bsn.SystemManagement'   # single module
./build.ps1 -Task Test -CodeCoverage                 # + JaCoCo coverage reports
./build.ps1 -Task Package                            # stage out/modules, zip out/packages
```

## Ground rules

These rules are enforced by the CI gate (Analyze + Test on
windows/ubuntu/macos, CodeQL, SonarCloud quality gate):

- **Never modify `ModuleVersion` in any `.psd1` in a PR**, never add release
  dates to `CHANGELOG.md`, and never convert the `## [Unreleased]` section
  into a versioned one. Fixes accumulate under `## [Unreleased]`; the version
  bump, rename, tag, and GitHub Release happen together in the single release
  step.
- **PSScriptAnalyzer must stay clean** (Error + Warning severity) across the
  whole module folder including tests. Keep `.ps1` / `.psm1` files ASCII-only.
- **Cross-edition compatibility**: code must work under Windows PowerShell
  5.1 and PowerShell 7 (see [AGENTS.md](AGENTS.md) for the known pitfalls,
  e.g. `Set-StrictMode` guards and no piping out of `foreach` statements).
- **Tests live inside each module** at `src/<Module>/tests/*.Tests.ps1`.
  Never write tests that suspend, sleep, or reboot a real machine - all
  suspend-path tests are mocked.
- **Every public cmdlet ships three doc artifacts**, updated together:
  comment-based help in the function, `en-US/about_*.help.txt`, and
  `docs/en-US/<Cmdlet>.md`. The Markdown pages feed the online help site
  (https://bsvn.github.io/Lmt.Commons/, built by DocFX), so each page
  must also be registered in `docs/toc.yml`.
- **Naming**: private helpers follow `<ApprovedVerb>-Bsn<Noun>`. Public
  cmdlet nouns must be collision-safe: prefix the noun with `Bsn` when
  the bare noun sits in a namespace Microsoft or other vendors plausibly
  own (`Transcript`, `Computer`, ...), e.g. `ConvertTo-BsnTranscript`,
  not `ConvertTo-Transcript`; bare nouns are fine only when already
  distinctive (`Start-InteractiveTranscript`). Command-name collisions
  resolve silently (last import wins) and module auto-loading bypasses
  `Import-Module -Prefix`, so uniqueness is a publish-time guarantee,
  not a per-import opt-in. Existing published names are grandfathered.
- C# interop code lives in real .NET projects per module; keep it
  warning-free for netstandard2.0. New testable C# goes in its own covered
  file under `src/Bsn.Host/tests/csharp`.
- Shared helpers belong in `src/Bsn.Common`, not duplicated in consumers.

## Submitting changes

1. Create a feature branch from `main`:
   `feature/<topic>`, `fix/<topic>`, or `chore/<topic>`.
2. Make your changes and add or update tests. Run
   `./build.ps1 -Task Analyze, Test` locally (ideally on both PowerShell
   editions and, when feasible, more than one OS).
3. Fold your change into the existing `## [Unreleased]` section of
   [CHANGELOG.md](CHANGELOG.md).
4. Push the branch and open a pull request. The PR template will ask for a
   summary, motivation, testing notes, and a checklist - fill it in.
5. Wait for the required checks (CI matrix, CodeQL, SonarCloud Gate). A
   human reviewer merges; do not merge your own PRs.

## Reporting issues

- Use the issue templates (bug report / feature request).
- **Security vulnerabilities are never reported via public issues** - see
  [SECURITY.md](SECURITY.md) for the private reporting process.

## License

This project is licensed under [GPL-3.0](LICENSE). By contributing you agree
that your contributions are licensed under the same license.
