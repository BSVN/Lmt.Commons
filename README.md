# LMT.Commons — the BSN PowerShell module family

[![CI](https://github.com/BSVN/Lmt.Commons/actions/workflows/CI.yml/badge.svg)](https://github.com/BSVN/Lmt.Commons/actions/workflows/CI.yml)
[![CodeQL](https://github.com/BSVN/Lmt.Commons/actions/workflows/CodeQL.yml/badge.svg)](https://github.com/BSVN/Lmt.Commons/actions/workflows/CodeQL.yml)
[![codecov](https://codecov.io/gh/BSVN/Lmt.Commons/branch/main/graph/badge.svg)](https://codecov.io/gh/BSVN/Lmt.Commons)
[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=BSVN_Lmt.Commons&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=BSVN_Lmt.Commons)
[![SonarCloud Tech Debt](https://sonarcloud.io/api/project_badges/measure?project=BSVN_Lmt.Commons&metric=sqale_index)](https://sonarcloud.io/summary/new_code?id=BSVN_Lmt.Commons)
[![Docs](https://github.com/BSVN/Lmt.Commons/actions/workflows/Docs.yml/badge.svg)](https://bsvn.github.io/Lmt.Commons/)
[![GitHub release](https://img.shields.io/github/v/release/BSVN/Lmt.Commons)](https://github.com/BSVN/Lmt.Commons/releases/latest)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

This repository is the single home for the **Bsn.* PowerShell modules**
published to the [PowerShell Gallery](https://www.powershellgallery.com/) —
the same monorepo/many-modules model used by azure-powershell, but built for
our own module family. **New modules are created with
[Plaster](https://github.com/PowerShellOrg/Plaster)**: the repository ships a
Plaster template that scaffolds a complete, consistent `Bsn.<Name>` module in
one command. Online help for every cmdlet lives at
**https://bsvn.github.io/Lmt.Commons/**.

| Module                                            | Description                                                            | PowerShell Gallery |
| ------------------------------------------------- | ---------------------------------------------------------------------- | ------------------ |
| [Bsn.Common](src/Bsn.Common)                      | Shared helpers for the Bsn.* module family (`Get-BsnOperatingSystem`) | [![Bsn.Common](https://img.shields.io/powershellgallery/v/Bsn.Common.svg)](https://www.powershellgallery.com/packages/Bsn.Common/) |
| [Bsn.Host](src/Bsn.Host)                          | Terminal session recording incl. TUI apps: `Start-`/`Stop-`/`Show-InteractiveTranscript` (asciicast v2/v3, optional GIF/WebM/MP4 render) | [![Bsn.Host](https://img.shields.io/powershellgallery/v/Bsn.Host.svg)](https://www.powershellgallery.com/packages/Bsn.Host/) |
| [Bsn.SystemManagement](src/Bsn.SystemManagement)  | Cross-platform basic system management: sleep/hibernate (`Suspend-Computer`) | [![Bsn.SystemManagement](https://img.shields.io/powershellgallery/v/Bsn.SystemManagement.svg)](https://www.powershellgallery.com/packages/Bsn.SystemManagement/) |

## Install

```powershell
Install-Module -Name Bsn.SystemManagement -Repository PSGallery
```

Modules are also mirrored to GitHub Packages
([org packages](https://github.com/orgs/BSVN/packages)) on every release.
GitHub Packages requires authentication even for public packages, so the
gallery remains the primary source; to install from the mirror:

```powershell
$token = '<github-pat-with-read-packages>'
Register-PSRepository -Name 'BsnGitHub' `
    -SourceLocation 'https://nuget.pkg.github.com/bsvn/index.json' `
    -Credential (New-Object PSCredential $token, (ConvertTo-SecureString $token -AsPlainText -Force)) `
    -InstallationPolicy Trusted
Install-Module -Name Bsn.SystemManagement -Repository BsnGitHub
```

## The first module: Bsn.SystemManagement

Provides basic system management functionality that PowerShell ships
without. Its first cmdlet, `Suspend-Computer`, puts a computer to sleep or
hibernates it — Windows, Linux and macOS, locally or remotely:

```powershell
Suspend-Computer -WhatIf     # see what would happen
Suspend-Computer             # confirm, then sleep the local machine
Suspend-Computer -Hibernate -Force
'PC-07', 'PC-12' | Suspend-Computer -Confirm:$false
```

The cmdlet implements the community request
[PowerShell#28164](https://github.com/PowerShell/PowerShell/issues/28164).
After the PowerShell Cmdlets Working Group declined to build it in-box and
recommended a community module, this is it. See
[docs/en-US/Suspend-Computer.md](docs/en-US/Suspend-Computer.md) for
platform details.

## Creating a new module (with Plaster)

Scaffold a new module with the wrapper script:

```powershell
./tools/New-BsnModule.ps1 -ModuleName Bsn.Example -CmdletName Get-Example -Description 'Example commands.'
```

or invoke Plaster directly against the template:

```powershell
Invoke-Plaster -TemplatePath ./templates/BsnModule -DestinationPath . `
               -ModuleName Bsn.Example -CmdletName Get-Example `
               -Description 'Example commands.' -Version 0.1.0 -Author BSVN
```

Either way you get a new module under `src/`:

```
src/Bsn.Example/
├── Bsn.Example.psd1            # manifest (GUID generated by Plaster)
├── Bsn.Example.psm1            # loader: dot-sources Public/ + Private/
├── Public/Get-Example.ps1      # scaffold for the first public command
├── Private/README.md           # helper function conventions
├── en-US/about_Bsn.Example.help.txt
└── tests/                      # Pester tests (manifest + command)
```

The new module is picked up automatically by `build.ps1` and CI — no
registration step needed.

## Development

```powershell
./build.ps1 -Bootstrap                      # install Pester, PSScriptAnalyzer, Plaster
./build.ps1                                 # analyze + test every module
./build.ps1 -Task Analyze, Test -ModulesFilter 'Bsn.SystemManagement'
./build.ps1 -Task Package                   # stage into out/modules, zip into out/packages
./build.ps1 -Task Publish -ApiKey <key>     # publish modules newer than the gallery
```

Requirements: PowerShell 5.1+ (7+ recommended). CI runs analysis and tests on
Windows, Linux and macOS for every push and pull request.

## Publishing to the PowerShell Gallery

Publishing is fully automated through GitHub Releases:

1. Implement/adjust cmdlets and tests, update `CHANGELOG.md`.
2. Bump `ModuleVersion` in the module's `.psd1`.
3. Push to `main`, then create a **GitHub Release** (e.g. `v0.1.0`). The
   [Publish workflow](.github/workflows/Publish.yml) fires automatically,
   runs the full gate (analyze, test, package) and publishes **every module
   whose version is newer than the one on the gallery** — so one release can
   update several modules at once, azure-powershell style. Modules are never
   re-published at the same version.

The workflow authenticates with the `PS_GALLERY_KEY` repository secret
(*Settings → Secrets and variables → Actions*). You can also trigger it
manually with the `dry_run` option to validate the pipeline without
touching the gallery.

## Repository layout

```
templates/BsnModule/     Plaster template that scaffolds new Bsn.* modules
tools/New-BsnModule.ps1  Plaster wrapper for scaffolding
src/                     one folder per generated module (the build targets it automatically)
docs/                    module documentation (built by DocFX into the online help site)
build.ps1                multi-module analyze/test/package/publish pipeline
```

## License

[GPL-3.0](LICENSE) © BSVN. Module scaffolding is done with
[Plaster](https://github.com/PowerShellOrg/Plaster) by the PowerShell
organization (MIT).
