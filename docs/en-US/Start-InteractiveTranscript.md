# Start-InteractiveTranscript

Records an interactive terminal session - including full-screen TUI
applications such as sconfig, vim, htop or nmtui - into a replayable
asciicast v2/v3 file.

Host-level terminal session recording for PowerShell. Implements
[PowerShell#28353](https://github.com/PowerShell/PowerShell/issues/28353)
following the parameter/format semantics of
[PowerShell-RFC#421](https://github.com/PowerShell/PowerShell-RFC/pull/421)
at module scope.

## Cmdlets

| Cmdlet | Purpose |
|---|---|
| `Start-InteractiveTranscript` | Record an interactive session (including TUI apps) to asciicast v2 or v3 |
| `Stop-InteractiveTranscript` | Finalize the recording from inside the recorded session |
| `Show-InteractiveTranscript` | Play a recording back in the console (`asciinema play`, PowerShell-native) |

## Start / Stop workflow

```powershell
Start-InteractiveTranscript                 # enter the recorded session
sconfig                                     # full-screen TUI - fully recorded
<anything else>
Stop-InteractiveTranscript                  # finalize; or just type 'exit'
```

The recorded command or shell runs inside a pseudo-terminal; everything
inside it is captured. On Windows the recorded `pwsh` imports `Bsn.Host`
automatically so `Stop-InteractiveTranscript` is available in the recording;
`exit` works everywhere. Ctrl+C aborts while keeping the cast playable.

```powershell
# Command-scoped recording ends when the command exits
Start-InteractiveTranscript -Command 'vim notes.txt' -Path .\notes.cast -Force

# Recording-aware prompt in the nested shell (Windows, optional)
Start-InteractiveTranscript -ShowRecordingIndicator

# asciicast v3 output (per the current RFC 421 draft: interval events,
# term header object, trailing 'x' exit event)
Start-InteractiveTranscript -Command 'nmtui' -Path .\demo\intro.cast -CastVersion 3

# With idle compression and a rendered video (needs agg + ffmpeg)
Start-InteractiveTranscript -Command 'nmtui' -Path .\demo\intro -RecordingFormat WebM -RecordIdleTimeLimit 5
```

- **RecordingFormat** - deliverable format, typed as the
  `BsnRecordingFormat` enum (names `Asciicast`/`Gif`/`WebM`/`Mp4`
  bind exactly like the previous strings; default `Asciicast`).
  `Gif` renders via [`agg`](https://github.com/asciinema/agg), `WebM`/`Mp4`
  additionally transcode via `ffmpeg`; missing tools degrade to a warning
  with the cast intact (RFC degradation contract).
- **CastVersion** - `2` (default, widest player compatibility) or `3`
  (matches the current RFC 421 draft: per-event intervals at millisecond
  precision, `term` header object, `x` exit event). `Show-InteractiveTranscript`
  reads both.
- **ShowRecordingIndicator** - optional recording-aware prompt in the
  nested shell (dot glyph + `REC PS <path>> `); Windows,
  interactive-shell mode only.

Playback:

```powershell
Show-InteractiveTranscript -Path .\audit\session01.cast
Show-InteractiveTranscript -Path .\audit\session01.cast -Speed 4 -IdleTimeLimit 2
asciinema play .\audit\session01.cast      # ecosystem interop
```

## Engines and platform support

| Platform | Engine | Timing |
| -------- | ------ | ------ |
| Windows  | ConPTY pseudo-console via compiled `lib/Bsn.Host.dll` (Windows 10 1809+, checked with a clear error) | exact, per chunk |
| Linux    | `script(1)` (util-linux `--log-timing`) | exact, per chunk |
| macOS    | `script(1)` (BSD) | approximated, per line |

Console resizes are forwarded to the pseudo-console and recorded as `r`
events. `-RecordInput` records keystrokes as `i` events (off by default -
it can capture secrets; the fact is noted in the cast header; Windows only
this release).

On Windows the recorded session runs under a UTF-8 console codepage (the
programmatic `chcp 65001` via `[Console]::OutputEncoding`/`InputEncoding`),
and the engine temporarily switches the calling console's output codepage
to UTF-8 for the duration of the recording, restoring it afterwards. This
keeps the live view of byte-writing TUIs (OpenCode and other Go/Node
applications) free of CP437 mojibake even on OEM-codepage consoles such as
cmd or the Windows PowerShell 5.1 host - the cast file itself is UTF-8
encoded regardless.

## Why not record the outer session like Start-Transcript?

PowerShell exposes **no public hook, event or handler** for intercepting the
host's console I/O at the C# API level; `CONIN$`/`CONOUT$`/`/dev/tty`
traffic of the current session is only reachable from the host process
itself (RFC 421 proposes exactly that, in-engine). The recorded nested
session is the closest a PowerShell Gallery module can deliver.

## Limitations

- `-RecordInput` is Windows-only in this release.
- When the calling pwsh has redirected standard I/O (CI, scripted
  harnesses), a warning is emitted: Windows may route the recorded process
  output around the pseudo-console. Run from an interactive terminal.
- Unix input recording is not supported yet (warning when requested).
