<#
.SYNOPSIS
    Parses an asciicast v2 or v3 file into a header and absolute-time event timeline.

.DESCRIPTION
    Pure parsing helper (no console interaction) used by
    Show-InteractiveTranscript. Validates the header (version 2 or 3) and
    returns the header object plus all parsed event arrays, normalized so
    that every event's first element is the ABSOLUTE time since recording
    start: v2 files already store absolute times; v3 files store intervals
    since the previous event, which are accumulated here. Comment lines
    (starting with '#', legal in v3 after the header) are skipped.
#>
function Get-BsnCastTimeline {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw ("The cast file '{0}' does not exist." -f $Path)
    }

    $castLines = [System.IO.File]::ReadAllLines($Path)
    if ($castLines.Count -eq 0) {
        throw ("The cast file '{0}' is empty." -f $Path)
    }

    $header = $castLines[0] | ConvertFrom-Json
    if (($header.version -ne 2) -and ($header.version -ne 3)) {
        throw ("The file '{0}' is not an asciicast v2 or v3 recording (header version: {1})." -f $Path, $header.version)
    }

    $events = [System.Collections.Generic.List[object]]::new()
    $absoluteTime = 0.0
    foreach ($castLine in ($castLines | Select-Object -Skip 1)) {
        $trimmedLine = $castLine.Trim()
        if (-not $trimmedLine) { continue }
        if ($trimmedLine.StartsWith('#')) { continue }

        $parsedEvent = $castLine | ConvertFrom-Json
        if ($header.version -eq 3) {
            # v3 stores intervals since the previous event; accumulate to absolute times.
            $absoluteTime += [double]$parsedEvent[0]
            $events.Add(@($absoluteTime, $parsedEvent[1], $parsedEvent[2]))
        }
        else {
            $events.Add(@([double]$parsedEvent[0], $parsedEvent[1], $parsedEvent[2]))
        }
    }

    return [pscustomobject]@{
        Header = $header
        Events = $events
    }
}
