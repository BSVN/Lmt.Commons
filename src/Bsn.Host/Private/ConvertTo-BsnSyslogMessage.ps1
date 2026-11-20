<#
.SYNOPSIS
    Renders an audit record as an RFC 5424 syslog message line.

.DESCRIPTION
    Pure helper (no network interaction) used by the Syslog target of
    Export-BsnAuditLog. Produces one RFC 5424 line:

        <PRI>1 TIMESTAMP HOSTNAME APP-NAME PROCID MSGID STRUCTURED-DATA MSG

    - PRI = facility * 8 + severity, with the severity taken from the
      canonical record (notice=5, info=6, debug=7, err=3).
    - HOSTNAME is the recorded host from the record's session block, or
      the RFC 5424 NILVALUE '-' when unknown.
    - APP-NAME is always 'bsn.host', PROCID is the session id, MSGID is
      'BSN_' + the event type (e.g. BSN_SESSION_INPUT).
    - STRUCTURED-DATA carries the correlation keys in a private enterprise
      SD-ID ('bsn@32473' is a placeholder - production deployments should
      register a free IANA Private Enterprise Number and pass their own
      SD-ID via -StructuredDataId). Parameter values are escaped per
      RFC 5424 ('\' -> '\\', '"' -> '\"', ']' -> '\]').
    - MSG is the compact canonical JSON record; control bytes from
      terminal content are JSON-escaped, which keeps the line 8-bit clean.

    The returned line carries NO transport framing; the TCP/TLS sender
    applies RFC 6587 octet-counting framing, and UDP sends the line as a
    datagram.
#>
function ConvertTo-BsnSyslogMessage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Record,

        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 23)]
        [int]$FacilityNumber,

        [string]$StructuredDataId = 'bsn@32473'
    )

    $severityNumbers = @{
        debug = 7
        info = 6
        notice = 5
        warning = 4
        err = 3
    }
    $severityName = [string]$Record.severity
    $severityNumber = if ($severityNumbers.ContainsKey($severityName)) { $severityNumbers[$severityName] } else { 6 }
    $pri = ($FacilityNumber * 8) + $severityNumber

    $msgId = 'BSN_' + ([string]$Record.event.type).ToUpperInvariant()

    $hostName = [string]$Record.session.host
    if (-not $hostName) {
        $hostName = '-'  # RFC 5424 NILVALUE when the recorded host is unknown.
    }

    $escapeValue = { param($value) $value.Replace('\', '\\').Replace('"', '\"').Replace(']', '\]') }
    $sessionId = & $escapeValue ([string]$Record.session.id)
    $castHash = & $escapeValue ([string]$Record.evidence.cast_sha256)
    $offsetMs = & $escapeValue ([string]$Record.position.offset_ms)
    $structuredData = '[{0} session_id="{1}" cast_sha256="{2}" offset_ms="{3}"]' -f $StructuredDataId, $sessionId, $castHash, $offsetMs

    $message = $Record | ConvertTo-Json -Compress -Depth 6

    return ('<{0}>1 {1} {2} bsn.host {3} {4} {5} {6}' -f $pri, $Record.time, $hostName, $sessionId, $msgId, $structuredData, $message)
}
