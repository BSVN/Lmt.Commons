<#
.SYNOPSIS
    Sends pre-built Splunk HEC event payloads to a Splunk HTTP Event
    Collector.

.DESCRIPTION
    Thin transport used by the SplunkHec target of Export-BsnAuditLog -
    no record logic, only HTTP. Each payload is one batch of HEC event
    envelopes (newline-separated JSON), POSTed to the
    /services/collector/event endpoint with the token authorization
    header. A non-zero response code is a terminating error.

    When -ChannelId and -Ack are supplied, each accepted batch returns an
    ack id which is verified against the /services/collector/ack endpoint
    (Splunk's indexed-event delivery confirmation). The token is never
    written to logs, verbose output or error messages.
#>
function Send-BsnSplunkHec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Payloads,

        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$Token,

        [string]$ChannelId = '',

        [switch]$Ack
    )

    $baseUri = $Uri.TrimEnd('/')
    foreach ($payload in $Payloads) {
        $headers = @{
            Authorization = 'Splunk {0}' -f $Token
        }
        if ($ChannelId) {
            $headers['X-Splunk-Request-Channel'] = $ChannelId
        }

        $response = Invoke-RestMethod -Method Post `
            -Uri ($baseUri + '/services/collector/event') `
            -Headers $headers -Body $payload -ContentType 'application/json'
        if ([int]$response.code -ne 0) {
            throw ('The Splunk HEC rejected an audit batch (code {0}: {1}).' -f $response.code, $response.text)
        }

        if ($Ack -and $ChannelId -and $response.ackId) {
            $ackId = [string]$response.ackId
            $ackBody = ConvertTo-Json -Compress -InputObject @{ acks = @([int]$ackId) } -Depth 3
            $ackResponse = Invoke-RestMethod -Method Post `
                -Uri ($baseUri + '/services/collector/ack') `
                -Headers $headers -Body $ackBody -ContentType 'application/json'
            $ackState = $ackResponse.acks.PSObject.Properties[$ackId]
            if ((-not $ackState) -or (-not $ackState.Value)) {
                throw ('The Splunk HEC did not acknowledge audit batch {0}.' -f $ackId)
            }
        }
    }
}
