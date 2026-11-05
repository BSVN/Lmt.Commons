# Start-InteractiveTranscript

Records an interactive terminal session - including full-screen TUI
applications - to a replayable asciicast v2 file.

`Start-InteractiveTranscript` fills the gap where `Start-Transcript` cannot
help: it records the terminal itself, not just the PowerShell pipeline. It
implements the community request
[PowerShell#28353](https://github.com/PowerShell/PowerShell/issues/28353) at
the scope a PowerShell Gallery module can deliver.

## Syntax

```powershell
Start-InteractiveTranscript [[-Command] <string>] [-Path <string>]
                             [-RecordInput] [-Force] [-WhatIf] [-Confirm]
```

## How it works

The recorded command runs inside a **pseudo-terminal** whose output stream
is proxied to the real console and teed, with timestamps, into an
[asciicast v2](https://github.com/asciinema/asciinema/blob/develop/asciicast-v2.md)
`.cast` file:

| Platform | Engine | Timing |
| -------- | ------ | ------ |
| Windows  | ConPTY pseudo-console (Windows 10 1809+) | exact, per chunk |
| Linux    | `script(1)` (util-linux `--log-timing`) | exact, per chunk |
| macOS    | `script(1)` (BSD) | approximated, per line |

Because the recorded process is attached to a real pseudo-terminal,
full-screen TUI applications (`sconfig`, `vim`, `htop`, `nmtui`, ...) are
fully captured - unlike `Start-Transcript`, whose transcripts are blank for
the duration of such applications.

Without `-Command`, an interactive shell is recorded (`pwsh` when available,
otherwise `powershell`/`cmd.exe` on Windows, `$SHELL` on Unix); type `exit`
in the nested shell to stop recording.

## Parameters

- **Command** - the command line to record; defaults to an interactive shell.
- **Path** - the `.cast` file to write; defaults to
  `InteractiveTranscript_<timestamp>.cast` in the temporary directory.
- **RecordInput** - also record keystrokes as `i` events. **Off by default**:
  captured input includes passwords typed at hidden prompts. Windows only
  in this release.
- **Force** - overwrite an existing cast file.

## Output

Returns a `Bsn.Host.InteractiveTranscript` object with `CastPath`,
`ExitCode` (also propagated to `$LASTEXITCODE`) and `DurationSec`.

## Examples

```powershell
# Record the full-screen sconfig tool (Windows Server)
Start-InteractiveTranscript -Command 'sconfig'

# Record an interactive shell session
$recording = Start-InteractiveTranscript -Path .\audit\session01.cast
# ... interact, then 'exit' the nested shell ...

# Replay the capture
asciinema play .\audit\session01.cast
```

## Limitations

- Recording targets **interactive console sessions**. When the calling
  PowerShell process has redirected standard I/O (CI pipelines, scripted
  harnesses), Windows may route the recorded process output around the
  pseudo-console; run `Start-InteractiveTranscript` from a real terminal.
- Transparent recording of the *entire* host session (without a nested
  shell/command) is only possible from inside the PowerShell host itself;
  that remains the subject of
  [PowerShell-RFC#421](https://github.com/PowerShell/RFC/pull/421).
- `-RecordInput` is Windows-only in this release.
- The Windows engine requires Windows 10 1809+ (ConPTY).
