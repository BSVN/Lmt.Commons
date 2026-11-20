<#
.SYNOPSIS
    Wraps an audit record in a Splunk HTTP Event Collector (HEC) payload.

.DESCRIPTION
    Pure helper (no network interaction) used by the SplunkHec target of
    Export-BsnAuditLog. Produces one HEC event envelope as compact JSON:

        {"time":<epoch.ms>,"host":...,"event":{...canonical record...},
         "source":"bsn.host","sourcetype":"bsn:audit","index":...,
         "fields":{"session_id":...,"event_type":...,"severity":...,
                   "cast_sha256":...}}

    - time is the record's RFC 3339 timestamp converted back to epoch
      seconds with millisecond precision (Splunk's preferred numeric form,
      which preserves exact event ordering).
    - host is emitted only when the recorded host is known.
    - index is emitted only when an index is requested (the HEC token or
      the default index applies otherwise).
    - fields carries the high-cardinality indexed fields so Splunk can
      extract them at index time without field discovery.

    Batching (multiple envelopes per request, newline-separated) and the
    HTTP transport itself live in Send-BsnSplunkHec.
#>
function ConvertTo-BsnSplunkEvent {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Record,

        [string]$Sourcetype = 'bsn:audit',

        [string]$Index = ''
    )

    $eventTime = [DateTime]::Parse(
        [string]$Record.time,
        [System.Globalization.CultureInfo]::InvariantCulture,
        ([System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal))
    $unixEpoch = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    $epochSeconds = [math]::Round(($eventTime.ToUniversalTime() - $unixEpoch).TotalSeconds, 3)

    $indexedFields = [ordered]@{
        session_id = [string]$Record.session.id
        event_type = [string]$Record.event.type
        severity = [string]$Record.severity
        cast_sha256 = [string]$Record.evidence.cast_sha256
    }

    $envelope = [ordered]@{
        time = $epochSeconds
    }
    $hostName = [string]$Record.session.host
    if ($hostName) {
        $envelope.host = $hostName
    }
    $envelope.event = $Record
    $envelope.source = 'bsn.host'
    $envelope.sourcetype = $Sourcetype
    if ($Index) {
        $envelope.index = $Index
    }
    $envelope.fields = $indexedFields

    return ($envelope | ConvertTo-Json -Compress -Depth 6)
}
