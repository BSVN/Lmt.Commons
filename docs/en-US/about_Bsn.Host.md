# about_Bsn.Host

## Short description

Host-level terminal session recording for PowerShell, capturing
full-screen TUI applications into replayable asciicast v2 files.

## Long description

The `Bsn.Host` module is the BSN counterpart of
`Microsoft.PowerShell.Host`: it covers the host/transcript domain. Its
main cmdlet, [Start-InteractiveTranscript](Start-InteractiveTranscript.md),
records what `Start-Transcript` cannot: the terminal session itself,
including full-screen interactive TUI applications such as `sconfig`,
`vim`, `htop` or `nmtui`.

## Start/stop workflow

[Start-InteractiveTranscript](Start-InteractiveTranscript.md) enters a
recorded interactive session (a nested shell). Everything run inside it -
including TUI applications - is recorded until the session ends:

```powershell
Start-InteractiveTranscript
<anything, including TUI apps>
Stop-InteractiveTranscript      # or 'exit'
```

On Windows the recorded shell (`pwsh`) imports `Bsn.Host` automatically,
so [Stop-InteractiveTranscript](Stop-InteractiveTranscript.md) is
available inside the recording. With `-Command`, recording ends when the
command exits; Ctrl+C aborts while keeping the cast file playable (it is
written incrementally).

A module cannot record the OUTER PowerShell session transparently:
PowerShell exposes no hook, event or handler for intercepting the host's
console I/O at the C# API level - only the host itself can (the subject
of PowerShell-RFC#421). The recorded nested session is the closest a
gallery module can deliver.

## Playback

[Show-InteractiveTranscript](Show-InteractiveTranscript.md) plays
recordings back in the console with original or adjusted timing
(`-Speed`, `-IdleTimeLimit`). Recordings also play anywhere the open
asciicast v2 ecosystem works, for example `asciinema play <file>.cast`.
On Windows the console output encoding is temporarily switched to UTF-8
during playback and restored afterwards, so characters outside CP437
(heavy box-drawing borders) do not degrade to `?` on OEM-codepage
consoles or in Windows PowerShell 5.1 hosts.

## Recording options (RFC 421 semantics)

| Option | Effect |
|---|---|
| `-CastVersion 2 \| 3` | asciicast format version: `2` (default, widest compatibility) or `3` (per-event intervals at millisecond precision, `term` header object, `x` exit event, per the current RFC 421 draft). Both versions play back. |
| `-ShowRecordingIndicator` | recording-aware prompt in the nested shell (dot glyph + `REC PS`); Windows, interactive-shell mode only |
| `-RecordingFormat Asciicast/Gif/WebM/Mp4` | deliverable format: Asciicast (default, `.cast` only), Gif (rendered via external `agg`), WebM/Mp4 (`agg` + `ffmpeg`). The `.cast` file is always written and remains the source of truth; missing tools degrade to a warning with the cast intact |
| `-RecordIdleTimeLimit <seconds>` | compresses idle gaps longer than the limit in the cast timing, keeping long, idle-heavy sessions watchable |
| `-RecordInput` | additionally records keystrokes as `i` events (Windows only in this release). Off by default because it can capture secrets typed at hidden prompts; when enabled, the fact is noted in the cast header |

Console resizes during a recording are forwarded to the pseudo console
and recorded as `r` events, so full-screen TUI applications that
re-query the terminal size replay correctly.

## Platform support and requirements

| Platform | Engine | Timing |
|---|---|---|
| Windows | ConPTY pseudo-console (requires Windows 10 1809 / Server 2019+; checked before recording with a clear error) | exact, per chunk |
| Linux | `script(1)` (util-linux `--log-timing`) | exact, per chunk |
| macOS | `script(1)` (BSD) | approximated, per line |

When the calling process has redirected standard I/O (CI, scripted
harnesses), a warning is emitted: Windows may route the recorded process
output around the pseudo-console. Run from an interactive console
session for full capture.

On Windows the console output codepage is temporarily switched to UTF-8
while recording (the live proxy writes UTF-8 bytes) and restored
afterwards, so the live view renders byte-writing TUIs correctly even on
OEM-codepage consoles such as `cmd` or the Windows PowerShell 5.1 host.

## Scenarios

- Audit and compliance records of privileged interactive sessions
- Support and incident response: reproduce exactly what was on screen
- Training material and shareable session captures

## Background

Implements the community request tracked in
[PowerShell#28353](https://github.com/PowerShell/PowerShell/issues/28353)
following the parameter and format semantics of
[PowerShell-RFC#421](https://github.com/PowerShell/PowerShell-RFC/pull/421)
at module scope. The C# ConPTY engine ships as a compiled assembly
(`lib/Bsn.Host.dll`); shared helpers live in the
[Bsn.Common](about_Bsn.Common.md) module.

## See also

- [Start-InteractiveTranscript](Start-InteractiveTranscript.md)
- [Stop-InteractiveTranscript](Stop-InteractiveTranscript.md)
- [Show-InteractiveTranscript](Show-InteractiveTranscript.md)
- [about_Bsn.Common](about_Bsn.Common.md)
