# Changelog

All notable changes to the modules in this repository are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the modules adhere to [Semantic Versioning](https://semver.org/).

## [Bsn.Host 0.1.0] - 2026-11-05

### Added

- `Bsn.Host` module (BSN counterpart of Microsoft.PowerShell.Host) with
  `Start-InteractiveTranscript`, which records an interactive terminal
  session - including full-screen TUI applications such as sconfig, vim,
  htop or nmtui - into a replayable asciicast v2 file, implementing the
  community request
  [PowerShell#28353](https://github.com/PowerShell/PowerShell/issues/28353)
  following the parameter and format semantics of
  [PowerShell-RFC#421](https://github.com/PowerShell/PowerShell-RFC/pull/421)
  at the scope a PowerShell Gallery module can deliver:
  - Windows: ConPTY pseudo-console engine (Windows 10 1809+), with optional
    keystroke recording via `-RecordInput`, console-resize forwarding and
    `r` events.
  - Linux: `script(1)` with exact per-chunk timing (util-linux).
  - macOS: `script(1)` with approximated per-line timing (BSD).
  - `-RecordingFormat` (Asciicast/Gif/WebM/Mp4): the cast file is always
    the source of truth; video renders via external `agg`/`ffmpeg` with
    RFC-conformant graceful degradation when tools are missing.
  - `-RecordIdleTimeLimit`: time-compresses long idle gaps for watchable
    playback.

### Changed (review feedback, PR #1)

- C# interop extracted from here-strings into real .NET projects compiled
  by `dotnet build` (`lib/Bsn.Host.dll`, `lib/Bsn.SystemManagement.dll`),
  loaded via `RequiredAssemblies`.
- Shared helpers factored into the new `Bsn.Common` module
  (`Get-BsnOperatingSystem` returning the `BsnOperatingSystem` enum,
  native `RuntimeInformation.IsOSPlatform` detection with a fallback for
  old Windows PowerShell); required by Bsn.Host and Bsn.SystemManagement.
- `Start-InteractiveTranscript`: Start-Transcript-like workflow - the
  default recorded shell is pwsh with Bsn.Host auto-imported, and
  `Stop-InteractiveTranscript` finalizes the recording from inside the
  session via a stop-signal channel understood by both engines.
- `Show-InteractiveTranscript`: plays recordings back in the console
  (`-Speed`, `-IdleTimeLimit`), backed by the pure `Get-BsnCastTimeline`
  parser.
- Environment constraints (Windows 10 1809+, script(1) presence, redirected
  standard I/O, non-console host) are now checked up front with explicit
  messages.
- `Invoke-BsnCastRender` gained cross-platform unit tests using fake
  `agg`/`ffmpeg` shims on PATH.

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
