<#
.SYNOPSIS
    Converts captured terminal output into an asciicast v2 (.cast) file.

.DESCRIPTION
    Writes the asciicast v2 header plus output ('o') event lines
    (https://github.com/asciinema/asciinema/blob/develop/asciicast-v2.md).

    Two parameter sets control event timing:

    - Timing (default): util-linux script --log-timing entries, each line
      '<+delta seconds> <byte count>' paired against the --log-out stream.
      Produces timing-exact events.
    - Approximated: no timing source (BSD script on macOS); output is split
      into line-based chunks whose timestamps are spread evenly across the
      measured session duration.

    The file is written as UTF-8 without BOM with LF line endings, matching
    the asciicast specification. All number formatting is culture-invariant.

    -OutputPath is the log script(1) kept. script(1) writes a start and a
    done message of its own into it, and util-linux's timing log covers
    only what the recorded session printed; the messages are left out
    before the timing is applied (see Select-BsnSessionOutput), so the cast
    holds the session's output and nothing else, timed as it happened.

    The header line and the event lines are written by the interop
    assembly's CastJson class, the same writer the ConPTY engine uses on
    Windows, so casts from the two engines are identical in structure and
    escaping: each line is one compact JSON value.

    -AuditMetadata carries the capture-time audit metadata as one
    AuditMetadata object and is written into the header's "bsn" block.
    AuditMetadata is the single definition of the block's shape for both
    recording engines and documents which block key each field fills. The
    block is omitted when no object is passed or the object carries no
    values.

    Parameters are listed below in the order the parts are written: the
    recorded stream, the cast file, the header fields, then the exit
    status, which is the last event of a cast.

.PARAMETER OutputPath
    Path of the raw captured output that becomes the cast's 'o' events:
    the script(1) --log-out stream or typescript file.

.PARAMETER TimingPath
    Path of the util-linux script(1) --log-timing log: one
    '<+delta seconds> <byte count>' entry per output chunk. Timing
    parameter set only; produces timing-exact events.

.PARAMETER DurationSec
    Measured duration of the session in seconds. Approximated parameter
    set only: with no timing log, line events are spread evenly across
    this duration.

.PARAMETER CastPath
    Path of the asciicast file to write. An existing file is overwritten.

.PARAMETER Width
    Terminal width in columns, recorded in the header. Default 80.

.PARAMETER Height
    Terminal height in rows, recorded in the header. Default 24.

.PARAMETER ShellName
    Name of the recorded command or shell, recorded in the header as
    env.SHELL and, in a v3 header, as "command". Default 'shell'.

.PARAMETER CastVersion
    Asciicast format to write: 2 (default) or 3.

.PARAMETER AuditMetadata
    Capture-time audit metadata for the header's "bsn" block, as a
    AuditMetadata object: the recorded session (GUID), the module that
    made the recording, the computer, the user, the process id and the
    version and edition of the PowerShell that made the recording.
    Start-InteractiveTranscript creates one per recording. Omit it to
    leave the block out.

.PARAMETER ExitCode
    Exit status of the recorded command. Written as the trailing 'x'
    event that finalizes a v3 cast; not written in a v2 cast.

.OUTPUTS
    None
        The function writes the cast file and returns nothing.
#>
function ConvertTo-BsnAsciicast {
    [CmdletBinding(DefaultParameterSetName = 'Timing')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(ParameterSetName = 'Timing')]
        [string]$TimingPath,

        [Parameter(ParameterSetName = 'Approximated')]
        [double]$DurationSec = 0,

        [Parameter(Mandatory = $true)]
        [string]$CastPath,

        [int]$Width = 80,

        [int]$Height = 24,

        [string]$ShellName = 'shell',

        [ValidateSet(2, 3)]
        [int]$CastVersion = 2,

        # Capture-time audit metadata, written into the header's "bsn" block.
        [Bsn.Host.Interop.AuditMetadata]$AuditMetadata,

        [int]$ExitCode = 0
    )

    $invariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
    $timingEntryPattern = '^\+?(\d+\.?\d*)\s+(\d+)\s*$'

    # script(1) writes a start and a done message of its own into the log.
    # They are not the session's output, and with a timing log they are not
    # timed either, so they are cut out before the timing is applied.
    $timedBytes = -1
    $timingLines = @()
    if ($PSCmdlet.ParameterSetName -eq 'Timing') {
        $timingLines = [System.IO.File]::ReadAllLines($TimingPath)
        $timedBytes = 0
        foreach ($timingLine in $timingLines) {
            if ($timingLine -match $timingEntryPattern) {
                $timedBytes += [int]$Matches[2]
            }
        }
    }
    $outputBytes = Select-BsnSessionOutput -Bytes ([System.IO.File]::ReadAllBytes($OutputPath)) -TimedBytes $timedBytes

    # Build the event plan: @{ Time; Offset; Count } triplets.
    $events = [System.Collections.Generic.List[object]]::new()

    if ($PSCmdlet.ParameterSetName -eq 'Timing') {
        $elapsed = 0.0
        $offset = 0
        foreach ($timingLine in $timingLines) {
            if ($timingLine -match $timingEntryPattern) {
                $elapsed += [double]::Parse($Matches[1], $invariantCulture)
                $count = [int]$Matches[2]
                if (($count -gt 0) -and ($offset -lt $outputBytes.Length)) {
                    if (($offset + $count) -gt $outputBytes.Length) {
                        $count = $outputBytes.Length - $offset
                    }
                    $events.Add([pscustomobject]@{ Time = $elapsed; Offset = $offset; Count = $count })
                    $offset += $count
                }
            }
        }
        if ($offset -lt $outputBytes.Length) {
            $events.Add([pscustomobject]@{ Time = $elapsed; Offset = $offset; Count = $outputBytes.Length - $offset })
        }
    }
    else {
        # Approximated: one event per line, spread evenly across the duration.
        $lineBreaks = [System.Collections.Generic.List[int]]::new()
        for ($index = 0; $index -lt $outputBytes.Length; $index++) {
            if ($outputBytes[$index] -eq 10) {
                $lineBreaks.Add($index)
            }
        }

        $chunkCount = $lineBreaks.Count
        if (($lineBreaks.Count -eq 0) -or ($lineBreaks[$lineBreaks.Count - 1] -ne ($outputBytes.Length - 1))) {
            $chunkCount++
        }
        $interval = if ($chunkCount -gt 1) { ($DurationSec / ($chunkCount - 1)) } else { 0 }

        $eventTime = 0.0
        $offset = 0
        foreach ($breakIndex in $lineBreaks) {
            $events.Add([pscustomobject]@{ Time = $eventTime; Offset = $offset; Count = ($breakIndex - $offset + 1) })
            $offset = $breakIndex + 1
            $eventTime += $interval
        }
        if ($offset -lt $outputBytes.Length) {
            $events.Add([pscustomobject]@{ Time = $eventTime; Offset = $offset; Count = $outputBytes.Length - $offset })
        }
    }

    $timestamp = [long]([System.DateTime]::UtcNow - [System.DateTime]::new(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)).TotalSeconds
    $decoder = [System.Text.Encoding]::UTF8.GetDecoder()

    $writer = [System.IO.StreamWriter]::new($CastPath, $false, [System.Text.UTF8Encoding]::new($false))
    $writer.NewLine = "`n"
    try {
        # Both recording engines write their header and their event lines
        # through the interop assembly's CastJson (System.Text.Json), so a
        # cast from the script(1) engine is built exactly like one from the
        # ConPTY engine. A null AuditMetadata object, or one that carries
        # no values, leaves the "bsn" block out of the header.
        $writer.WriteLine([Bsn.Host.Interop.CastJson]::Header($CastVersion, $Width, $Height, $timestamp, $ShellName, 'Bsn.Host interactive transcript', $AuditMetadata))

        # v3 events carry intervals with millisecond precision, v2 events
        # absolute times with microsecond precision.
        $timeDecimals = if ($CastVersion -eq 3) { 3 } else { 6 }
        $previousTime = 0.0
        # Issue #20: response-eliciting query sequences are filtered out of
        # the cast here too - Unix script(1) logs carry the same query bytes
        # from the recorded children, and casts must not contain them (any
        # player re-broadcasts them; the terminal answers into the console
        # input buffer). The filter state persists across events, which
        # handles sequences that span timing-chunk boundaries.
        $queryFilter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
        foreach ($castEvent in $events) {
            $charBuffer = [char[]]::new($castEvent.Count)
            $charCount = $decoder.GetChars($outputBytes, $castEvent.Offset, $castEvent.Count, $charBuffer, 0)
            $eventText = $queryFilter.Filter([string]::new($charBuffer, 0, $charCount))

            $eventTime = $castEvent.Time
            if ($CastVersion -eq 3) {
                # v3: interval since the previous event.
                $eventTime = $castEvent.Time - $previousTime
                if ($eventTime -lt 0) { $eventTime = 0 }
            }
            $previousTime = $castEvent.Time

            $writer.WriteLine([Bsn.Host.Interop.CastJson]::Event($eventTime, $timeDecimals, 'o', $eventText))
        }

        # A trailing partial query/sequence held by the filter is real recorded
        # content - emit it as a final event at the last known timestamp (an
        # interval of zero in a v3 cast).
        $filterTail = $queryFilter.FlushRemaining()
        if ($filterTail.Length -gt 0) {
            $tailTime = if ($CastVersion -eq 3) { 0.0 } else { $previousTime }
            $writer.WriteLine([Bsn.Host.Interop.CastJson]::Event($tailTime, $timeDecimals, 'o', $filterTail))
        }

        if ($CastVersion -eq 3) {
            # v3 recordings are finalized with an 'x' exit-status event.
            $writer.WriteLine([Bsn.Host.Interop.CastJson]::Event(0, $timeDecimals, 'x', [string]$ExitCode))
        }
    }
    finally {
        $writer.Dispose()
    }
}
