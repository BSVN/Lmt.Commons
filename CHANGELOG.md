# Changelog

All notable changes to the modules in this repository are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the modules adhere to [Semantic Versioning](https://semver.org/).

## [Bsn.SystemManagement 0.2.0] - 2026-11-06

### Changed

- Local Windows suspend now calls the compiled
  `Bsn.SystemManagement.Interop.PowerProf` assembly (netstandard2.0,
  loaded via RequiredAssemblies); the self-contained
  `scripts/Suspend-Action.ps1` remains the remote-execution payload and
  the Unix implementation.
- Now depends on the shared `Bsn.Common` module (RequiredModules) for
  operating-system detection via the native `BsnOperatingSystem` enum.

## [Bsn.Host 0.1.0] - 2026-11-05

### Added

- `BsnRecordingFormat` consolidated to a native PowerShell enum in
  `Bsn.Host.psm1` (DRY: one enum pattern repo-wide, no C#/native split):
  after the corrected Pester model, the native constraint survives this
  repo's `Mock -ModuleName` + module-internal invocation shape exactly as
  the C# version did. Names and binding behavior are unchanged.
- `Test-BsnRecordingEnvironment`'s `-Platform` parameter is now typed as
  the real native `BsnOperatingSystem` enum (the ValidateSet-string
  workaround is gone): a bare constraint bound at compile time via the
  file's `using module` header survives `Mock -ModuleName` with
  module-internal invocation - the Pester interaction model fully
  verified on PS 5.1 and PS 7 (test-scope mocking needs
  `-RemoveParameterType`; setup-time failures indicate never-bound
  constraints; `using module` in test files and type accelerators do not
  help the generated proxy; assembly enums are always safe).
- `-RecordingFormat` is now typed as the `Bsn.Host.BsnRecordingFormat`
  enum (defined in Bsn.Host.csproj, the RFC 421 RecordingOutputFormat
  shape): assembly-backed so Pester mocks of the renderer stay safe,
  while names (Asciicast/Gif/WebM/Mp4) still bind exactly as before.
  Completes the keyword-enum investigation: native-enum param constraints
  break Pester's Mock in every scope (accelerator, test-file `using
  module` and same-module placements all falsified on PS 5.1 and PS 7);
  assembly enums are Mock-safe.
- `-CastVersion <2|3>`: asciicast v3 output per the updated
  PowerShell-RFC#421 draft (interval-based events at millisecond
  precision, `term` header object, final `x` exit-status event) alongside
  v2 (default, widest ecosystem compatibility). Both engines,
  `Show-InteractiveTranscript` (normalizes v3 intervals to absolute times,
  skips v3 comment lines) and `Optimize-BsnCastIdleTime` (direct interval
  clamping for v3) support both versions.
- `-ShowRecordingIndicator`: optional recording-aware prompt in the nested
  shell (dot glyph + 'REC PS'), Windows interactive-shell mode only.
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
- `BsnOperatingSystem` is a native PowerShell enum in `Bsn.Common.psm1`
  (no compiled assembly): the original C# version was a workaround for a
  misdiagnosed failure. Bisecting on PS 5.1 and PS 7 showed the real root
  cause was `[OutputType([BsnOperatingSystem])]` - a keyword-type literal
  inside an attribute in a dot-sourced file cannot bind (attributes bind
  at compile time and cannot resolve dynamic enums), which poisoned the
  first function call. Consumers use bare names in function bodies
  (bodies resolve cross-module once Bsn.Common is loaded), string-typed
  parameters with ValidateSet where Pester mocks apply, and attribute
  positions use the string form; `using module` is avoided because
  its parse-time PSModulePath resolution breaks path-imported dev flows.
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

## [Bsn.SystemManagement 0.1.0] - 2026-11-05

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
