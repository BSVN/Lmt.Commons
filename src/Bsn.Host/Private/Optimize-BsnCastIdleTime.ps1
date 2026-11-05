<#
.SYNOPSIS
    Time-compresses idle periods in a cast file.

.DESCRIPTION
    Implements the -RecordIdleTimeLimit semantics of RFC 421 (Terminal
    Session Recording): inter-event gaps longer than the limit are reduced
    to exactly the limit, so playback and video renders of long, idle-heavy
    sessions stay watchable. Event payloads are untouched; only the leading
    timestamp of each event line is rewritten. A limit of 0 (the cmdlet
    default) means unlimited and skips processing entirely.
#>
function Optimize-BsnCastIdleTime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$LimitSec
    )

    $invariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
    $timestampPattern = '^\[(\d+(?:\.\d+)?)'

    $adjustedLines = [System.Collections.Generic.List[string]]::new()
    $previousTime = $null

    foreach ($castLine in [System.IO.File]::ReadAllLines($Path)) {
        if ($castLine -match $timestampPattern) {
            $eventTime = [double]::Parse($Matches[1], $invariantCulture)
            if (($null -ne $previousTime) -and ((($eventTime - $previousTime) -gt $LimitSec))) {
                $eventTime = $previousTime + $LimitSec
            }
            $previousTime = $eventTime
            $adjustedLines.Add([regex]::Replace($castLine, '^\[\d+(?:\.\d+)?', ('[' + $eventTime.ToString('0.######', $invariantCulture))))
        }
        else {
            $adjustedLines.Add($castLine)
        }
    }

    $writer = [System.IO.StreamWriter]::new($Path, $false, [System.Text.UTF8Encoding]::new($false))
    $writer.NewLine = "`n"
    try {
        foreach ($adjustedLine in $adjustedLines) {
            $writer.WriteLine($adjustedLine)
        }
    }
    finally {
        $writer.Dispose()
    }
}
