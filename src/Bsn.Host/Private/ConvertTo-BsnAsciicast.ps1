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

        [string]$ShellName = 'shell'
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
        $writer.WriteLine(('{{"version": 2, "width": {0}, "height": {1}, "timestamp": {2}, "title": "Bsn.Host interactive transcript", "env": {{"SHELL": "{3}", "TERM": "xterm-256color"}}}}' -f `
                $Width, $Height, $timestamp, $ShellName))

        foreach ($castEvent in $events) {
            $charBuffer = [char[]]::new($castEvent.Count)
            $charCount = $decoder.GetChars($outputBytes, $castEvent.Offset, $castEvent.Count, $charBuffer, 0)
            $eventText = [string]::new($charBuffer, 0, $charCount)
            $jsonText = $eventText | ConvertTo-Json -Compress
            $writer.WriteLine(('[{0}, "o", {1}]' -f $castEvent.Time.ToString('0.######', $invariantCulture), $jsonText))
        }
    }
    finally {
        $writer.Dispose()
    }
}
