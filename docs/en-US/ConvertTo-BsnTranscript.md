# ConvertTo-BsnTranscript

Converts an asciicast (`.cast`) recording into a Start-Transcript-style
plain-text transcript: the readable, auditor-facing rendering of the
recorded evidence (issue
[#22](https://github.com/BSVN/Lmt.Commons/issues/22)).

One recording, several consumers - deliberate layering, no parallel
parsers:

| Artifact | Consumer |
|---|---|
| `.cast` file | bit-exact evidence, replayable |
| `Show-InteractiveTranscript` player | humans, interactive replay |
| `Start-Transcript`-style `.txt` (**this cmdlet**) | humans / auditors - readable rendering of the evidence |

## Usage

```powershell
ConvertTo-BsnTranscript session01.cast -OutPath session01.txt     # classic txt file
ConvertTo-BsnTranscript session01.cast | Set-Content audit01.txt  # pipeline
Get-ChildItem .\audit -Filter *.cast | ConvertTo-BsnTranscript    # every recording
```

The conversion is pure: it reuses the same `Get-BsnCastTimeline` parser
as the player (no console replay, no engine involvement), so a given
cast always converts to byte-identical text on Windows PowerShell 5.1
and PowerShell 7, on every operating system.

## Header modes

`-HeaderMode Standard` (default) mimics the Start-Transcript frame. The
engine-derived fields (Username, RunAs User, Machine, Process ID,
PSVersion, PSEdition) are not recorded inside a cast: they are written
blank - real transcripts emit blank fields too - unless supplied via
parameters. Host Application is derived from the cast header
(`command`, else `env.SHELL`) and can be overridden.

```text
**********************
PowerShell transcript start
Start time: 20261108142301
Username:
RunAs User:
Machine:
Host Application: pwsh
Process ID:
PSVersion:
PSEdition:
**********************
Transcript started, output file is session01.txt

<session output: echoed commands interleaved with result text>

**********************
PowerShell transcript end
End time: 20261108142345
**********************
```

`-HeaderMode Bsn` adds the audit frame around the same transcript:

```text
Session Id: bsn-1a2b3c4d5e6f
Recorded By: Bsn.Host 0.2.4
Terminal Size: 100x40
Cast File: C:\audit\session01.cast
Cast SHA256: 4c9feab0...          <- proves which cast the text was rendered from
Exit Code: 0                      <- v3 recordings only
```

The session id defaults to a deterministic value derived from the cast
hash (`bsn-` plus its first twelve hex characters) and can be supplied
via `-SessionId`.

## Rendering fidelity

`-RenderMode Strip` (default) concatenates the output (`o`) events in
timeline order, strips CSI/OSC/VT escape sequences and resolves
carriage-return overtype and backspace: progress bars collapse to their
final frame (with the residue of longer previous lines left in place,
exactly like a real terminal). Line-oriented shell sessions convert
cleanly because ConPTY/PTY echo puts the typed input into the output
stream - exactly what Start-Transcript captures.

Documented limitation: full-screen TUI applications (vim, htop, the
OpenCode TUI) redraw the screen with cursor addressing and produce
columnar residue in the Strip tier. The cast remains the exact evidence
and replays with `Show-InteractiveTranscript`; a full VT emulation tier
may follow in a later release.

`-AnnotateCommands` inserts recorded keystroke (`i`) events as
`> typed-text` lines at their timeline position - for sessions recorded
with `-RecordInput` where the input was NOT echoed (password prompts,
`Read-Host -AsSecureString`). On echoing sessions commands then appear
twice.

## Encoding and line endings

Real Start-Transcript files are UTF-16LE on Windows PowerShell 5.1 and
UTF-8 on PowerShell 7. The export standardizes instead: UTF-8 without
BOM with CRLF line endings on every edition and OS. `-Encoding`
switches to ASCII, Unicode (UTF-16LE, with BOM), BigEndianUnicode or
UTF32.

## Privacy

Echoed input in a recording contains whatever was typed, including
secrets at prompts that do not suppress echo; `-AnnotateCommands`
additionally surfaces recorded `-RecordInput` keystrokes. The
transcript inherits that property - handle the txt like the cast
itself.
