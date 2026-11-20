# Show-InteractiveTranscript

Plays back an interactive transcript recording in the console.

`Show-InteractiveTranscript` re-emits the output stream of an asciicast
v2/v3 (`.cast`) file - as recorded by
[Start-InteractiveTranscript](Start-InteractiveTranscript.md) or produced
by `asciinema rec` - in the current console, with the original timing. It
is the PowerShell-native equivalent of `asciinema play`, covering
view-back scenarios directly inside PowerShell.

## Syntax

```powershell
Show-InteractiveTranscript [-Path] <string> [-IdleTimeLimit <double>] [-Speed <double>]
```

## Parameters

- **Path** - the asciicast (`.cast`) file to play back. Mandatory,
  position 0, accepts pipeline input (`Get-ChildItem .\audit\*.cast |
  Show-InteractiveTranscript` replays every recording in turn).
- **IdleTimeLimit** - when greater than zero (seconds), pauses longer
  than this limit are shortened to it, mirroring asciinema's
  `--idle-time-limit` behavior. Zero (default) preserves the original
  timing.
- **Speed** - playback speed multiplier; `1` (default) is original
  speed. Accepts `0.1` (ten times slower) to `100` (one hundred times
  faster).

## Examples

```powershell
Show-InteractiveTranscript -Path .\audit\session01.cast
```

Replays the recording at original speed.

```powershell
Show-InteractiveTranscript -Path .\audit\session01.cast -Speed 4 -IdleTimeLimit 2
```

Replays four times faster and skips pauses longer than two seconds.

```powershell
asciinema play .\audit\session01.cast
```

The same file also plays with the open `asciicast` ecosystem - recordings
are standard asciicast v2/v3 files.

## Notes

- Input (`i`) events are not replayed; resize (`r`) events are ignored -
  the current console keeps its own size.
- Both asciicast versions are supported: v2 (absolute event times) and
  v3 (per-event intervals per the RFC 421 draft), with v3 intervals
  normalized to absolute times during playback.
- On Windows the console output encoding is temporarily switched to
  UTF-8 for the playback and restored afterwards: Windows PowerShell 5.1
  hosts write `[Console]` output through the console output codepage,
  which would otherwise render characters outside CP437 (e.g. heavy
  box-drawing borders) as literal `?`. The recorded cast file itself is
  lossless UTF-8 either way.

## See also

- [Start-InteractiveTranscript](Start-InteractiveTranscript.md)
- [Stop-InteractiveTranscript](Stop-InteractiveTranscript.md)
- [about_Bsn.Host](about_Bsn.Host.md)
