# Changelog

All notable changes to the modules in this repository are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the modules adhere to [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-11-05

### Added

- Repository infrastructure for generating the `Bsn.*` module family with
  [Plaster](https://github.com/PowerShellOrg/Plaster) and publishing each
  module independently to the PowerShell Gallery.
- `templates/BsnModule` Plaster template that scaffolds a new `Bsn.*` module
  with manifest, loader, `Public/`/`Private/` command structure, about-topic
  and Pester tests.
- `tools/New-BsnModule.ps1` wrapper around `Invoke-Plaster`.
- `build.ps1` multi-module Analyze / Test / Package / Publish pipeline.
- `Bsn.SystemManagement` module (v0.1.0) with `Suspend-Computer`, a
  cross-platform sleep/hibernate cmdlet implementing the community request
  [PowerShell#28164](https://github.com/PowerShell/PowerShell/issues/28164):
  - Windows: documented `SetSuspendState` API via P/Invoke.
  - Linux: `systemctl suspend`/`hibernate` with `loginctl` fallback.
  - macOS: `pmset sleepnow`.
  - Remote computers over PowerShell remoting (WinRM/SSH).
