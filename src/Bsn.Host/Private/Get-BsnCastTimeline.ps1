<#
.SYNOPSIS
    Parses an asciicast v2 file into a header and event timeline.

.DESCRIPTION
    Pure parsing helper (no console interaction) used by
    Show-InteractiveTranscript. Validates the header (version 2) and
    returns the header object plus all parsed event arrays. Kept separate
    so the parsing logic is unit-testable.
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
    if ($header.version -ne 2) {
        throw ("The file '{0}' is not an asciicast v2 recording (header version: {1})." -f $Path, $header.version)
    }

    $events = @(
        foreach ($castLine in ($castLines | Select-Object -Skip 1)) {
            if ($castLine.Trim()) {
                , ($castLine | ConvertFrom-Json)
            }
        }
    )

    return [pscustomobject]@{
        Header = $header
        Events = $events
    }
}
