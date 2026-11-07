# Changelog

All notable changes to the modules in this repository are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the modules adhere to [Semantic Versioning](https://semver.org/).

## [Bsn.Host 0.2.2] - 2026-11-07

### Fixed

- Recordings of byte-writing TUI applications (OpenCode, other
  Go/Bubble Tea and Node TUIs, `cmd /c type`) are no longer corrupted
  to codepage mojibake: the recorded session now bootstraps the console
  codepage to UTF-8 before the command runs (the programmatic
  `chcp 65001` via `[Console]::OutputEncoding`/`InputEncoding`).
  Root cause: a fresh pseudo console starts with the OEM output
  codepage (probe: 437), and OEM-codepage-decoding conhosts decode a
  child's stdout BYTES with it - one box-drawing character
  (U+2500, UTF-8 `E2 94 80`) arrived as three CP-decoded characters.
  pwsh's own output was immune (`WriteConsoleW`), which is why
  synthetic pwsh probes passed while real byte-writing TUIs were
  corrupted. [#5](https://github.com/BSVN/Lmt.Commons/issues/5)
- Interop assembly loading is now managed by the module loader (via the
  shared Bsn.Common helper) instead of the manifest's
  `RequiredAssemblies`: re-importing with `Import-Module -Force` reuses
  the already-loaded assembly instead of failing with
  `FileLoadException`, and importing after `Update-Module` fails with
  actionable guidance ("restart the session") instead of a raw
  `FileLoadException`. A session restart is still required to switch
  assembly versions in one process: PowerShell/.NET cannot host two
  versions of the same assembly name, so a same-session update is a
  platform limitation, not a module defect.
  [#15](https://github.com/BSVN/Lmt.Commons/issues/15)
- The interop assembly is now stamped with the module version as its
  `AssemblyVersion` at build time (build.ps1 passes
  `-p:Version=<ModuleVersion from the psd1>`, which stays the single
  source of truth). Previously every shipped module version carried the
  default `AssemblyVersion` 1.0.0.0, so the loader could not tell an
  already-loaded old version from the same version, silently reusing
  mismatched interop code. Guard tests in Bsn.Host and
  Bsn.SystemManagement assert the built DLL version equals the manifest
  version.
  [#15](https://github.com/BSVN/Lmt.Commons/issues/15)

### Added

- System tests reproducing each reported corruption scenario against
  the real ConPTY engine: the OEM-codepage probe (the recorded session
  must report codepage 65001), a raw byte-writing child (Go/Node TUI
  output semantics) asserted character-for-character, a real OpenCode
  TUI session (when installed), and metacharacter round-trip through
  the real engine (issues #5 and #7).

## [Bsn.SystemManagement 0.2.1] - 2026-11-07

### Fixed

- Same interop assembly loading change as Bsn.Host 0.2.2 (loader-managed
  via Bsn.Common 0.1.1, version-stamped assembly).
  `Suspend-Computer` behavior is unchanged.
  [#15](https://github.com/BSVN/Lmt.Commons/issues/15)

## [Bsn.Common 0.1.1] - 2026-11-07

### Added

- Private `Import-BsnInteropAssembly` helper used by the Bsn.* module
  loaders (which pass their module root; the DLL is resolved from
  `<module>/lib/<name>.dll`): reuses an already-loaded same-version
  interop assembly on `Import-Module -Force`, and fails with actionable
  guidance when a different version is already in the session.
  Unit tests cover the missing-DLL, fresh-load, same-version reuse and
  cross-version guidance paths.
  [#15](https://github.com/BSVN/Lmt.Commons/issues/15)

## [Bsn.Host 0.2.1] - 2026-11-07

### Fixed

- Cast recordings no longer corrupt multi-byte UTF-8 characters at
  4096-byte chunk boundaries: the ConPTY engine and the Unix converter
  keep persistent `System.Text.Decoder` instances for the output and
  input streams, so multi-byte sequences split across reads decode
  correctly (verified with an oh-my-posh nerd-font prompt stress test:
  zero U+FFFD in the cast).
  [#5](https://github.com/BSVN/Lmt.Commons/issues/5)
- Cast files are written with incremental flushes (AutoFlush in the
  ConPTY CastWriter; header + per-event flush in the converter), so a
  recording whose process dies abnormally still leaves a valid,
  playable cast instead of losing the header and tail to stream
  buffering. [#6](https://github.com/BSVN/Lmt.Commons/issues/6)
- `Start-InteractiveTranscript -Command` values containing pipes,
  quotes and other shell metacharacters are no longer mangled: the
  command is wrapped in `pwsh -EncodedCommand` (Base64) instead of
  `cmd.exe /d /c`. [#7](https://github.com/BSVN/Lmt.Commons/issues/7)
- Starting a recording from a host with BOTH stdin and stdout
  redirected (CI, scripted harnesses) is now a terminating error with
  guidance instead of silently producing an empty cast that reports
  success. [#8](https://github.com/BSVN/Lmt.Commons/issues/8)

### Notes

- Bsn.Host 0.2.0 was never published to the PowerShell Gallery: the
  v0.2.0 release tag predates this module's version bump, so the
  idempotent Publish task correctly skipped it. 0.2.1 is the first
  gallery release containing the fixes above.

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
