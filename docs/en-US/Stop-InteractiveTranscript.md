# Stop-InteractiveTranscript

Stops the interactive transcript running in the current session.

`Stop-InteractiveTranscript` is the `Stop-Transcript` half of the
`Start-Transcript`-like workflow provided by the `Bsn.Host` module: it
finalizes the cast file started by
[Start-InteractiveTranscript](Start-InteractiveTranscript.md) and returns
control to the outer shell.

## Syntax

```powershell
Stop-InteractiveTranscript [-WhatIf] [-Confirm]
```

## How it works

The cmdlet must run **inside** the recorded session - the nested shell
entered by [Start-InteractiveTranscript](Start-InteractiveTranscript.md),
or any child of it. It writes a stop request to the file named by the
`BsnHostRecordingStopFile` environment variable, which the recording
engine and all recorded descendants inherit; the engine observes the file
and finalizes the cast momentarily.

- On Windows the default recorded shell (`pwsh`) imports `Bsn.Host`
  automatically, so the cmdlet is available inside the recording out of
  the box.
- Typing `exit` in the recorded shell finalizes the recording as well.
- With `-Command`, the recording ends when the command exits; the cmdlet
  is only needed for interactive-shell recordings.

## Examples

```powershell
Start-InteractiveTranscript
PS> <work, TUI apps, ...>
PS> Stop-InteractiveTranscript
```

Records everything until `Stop-InteractiveTranscript` finalizes the cast
file and returns to the outer PowerShell session.

```powershell
Stop-InteractiveTranscript -WhatIf
```

Shows what would happen without writing a stop request.

## Parameters

- **WhatIf** - shows what would happen without touching anything.
- **Confirm** - prompts for confirmation before writing the stop request.

## Notes

- When no recording is active in the session, the cmdlet throws an
  explanatory terminating error instead of touching anything.
- If a stop request is already pending, the cmdlet does nothing, so it is
  safe to call twice.

## See also

- [Start-InteractiveTranscript](Start-InteractiveTranscript.md)
- [Show-InteractiveTranscript](Show-InteractiveTranscript.md)
- [about_Bsn.Host](about_Bsn.Host.md)
- `Start-Transcript`, `Stop-Transcript`
