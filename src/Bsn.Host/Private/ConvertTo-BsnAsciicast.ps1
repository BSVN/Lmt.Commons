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

    [int]$ExitCode = 0
    )

    $invariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
    $outputBytes = [System.IO.File]::ReadAllBytes($OutputPath)

    # Build the event plan: @{ Time; Offset; Count } triplets.
    $events = [System.Collections.Generic.List[object]]::new()

    if ($PSCmdlet.ParameterSetName -eq 'Timing') {
        $elapsed = 0.0
        $offset = 0
        foreach ($timingLine in [System.IO.File]::ReadAllLines($TimingPath)) {
            if ($timingLine -match '^\+?(\d+\.?\d*)\s+(\d+)\s*$') {
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
        if ($CastVersion -eq 3) {
            $writer.WriteLine(('{{"version": 3, "term": {{"cols": {0}, "rows": {1}, "type": "xterm-256color"}}, "timestamp": {2}, "command": "{3}", "title": "Bsn.Host interactive transcript", "env": {{"SHELL": "{3}", "TERM": "xterm-256color"}}}}' -f `
                    $Width, $Height, $timestamp, $ShellName))
        }
        else {
            $writer.WriteLine(('{{"version": 2, "width": {0}, "height": {1}, "timestamp": {2}, "title": "Bsn.Host interactive transcript", "env": {{"SHELL": "{3}", "TERM": "xterm-256color"}}}}' -f `
                    $Width, $Height, $timestamp, $ShellName))
        }

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
            $jsonText = $eventText | ConvertTo-Json -Compress

            $formattedTime = if ($CastVersion -eq 3) {
                # v3: interval since the previous event, millisecond precision (spec recommendation).
                $interval = [math]::Round($castEvent.Time - $previousTime, 3)
                if ($interval -lt 0) { $interval = 0 }
                $previousTime = $castEvent.Time
                $interval.ToString('0.###', $invariantCulture)
            }
            else {
                $castEvent.Time.ToString('0.######', $invariantCulture)
            }

            $writer.WriteLine(('[{0}, "o", {1}]' -f $formattedTime, $jsonText))
        }

        # A trailing partial query/sequence held by the filter is real recorded
        # content - emit it as a final event at the last known timestamp.
        $filterTail = $queryFilter.FlushRemaining()
        if ($filterTail.Length -gt 0) {
            $formattedTime = if ($CastVersion -eq 3) { '0' } else { $previousTime.ToString('0.######', $invariantCulture) }
            $writer.WriteLine(('[{0}, "o", {1}]' -f $formattedTime, ($filterTail | ConvertTo-Json -Compress)))
        }

        if ($CastVersion -eq 3) {
            # v3 recordings are finalized with an 'x' exit-status event.
            $writer.WriteLine(('[0, "x", "{0}"]' -f $ExitCode))
        }
    }
    finally {
        $writer.Dispose()
    }
}
