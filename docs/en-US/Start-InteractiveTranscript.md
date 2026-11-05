# Bsn.Host cmdlets

Host-level terminal session recording for PowerShell. Implements
[PowerShell#28353](https://github.com/PowerShell/PowerShell/issues/28353)
following the parameter/format semantics of
[PowerShell-RFC#421](https://github.com/PowerShell/PowerShell-RFC/pull/421)
at module scope.

## Cmdlets

| Cmdlet | Purpose |
|---|---|
| `Start-InteractiveTranscript` | Record an interactive session (including TUI apps) to asciicast v2 |
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

# With idle compression and a rendered video (needs agg + ffmpeg)
Start-InteractiveTranscript -Command 'nmtui' -Path .\demo\intro -RecordingFormat WebM -RecordIdleTimeLimit 5
```

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
