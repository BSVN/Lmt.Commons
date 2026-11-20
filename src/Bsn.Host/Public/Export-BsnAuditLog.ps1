<#
.SYNOPSIS
    Exports an asciicast recording's audit log to NDJSON, syslog (RFC
    5424), Splunk HEC or the audit transcript.

.DESCRIPTION
    Converts the recording into the canonical audit records
    (ConvertTo-BsnAuditRecord - the machine-readable index of the
    recorded evidence, "the log is the index, the cast is the evidence")
    and forwards them through one of four targets:

    - NDJSON: one canonical JSON record per line, UTF-8 without BOM with
      LF line endings - the local, SIEM-friendly file sink.
    - Syslog: RFC 5424 lines (PRI = facility * 8 + severity, APP-NAME
      'bsn.host', PROCID = session id, MSGID = BSN_<EVENTTYPE>, private
      structured data with the correlation keys, MSG = compact canonical
      JSON) sent over TLS (default), plain TCP or UDP; TCP/TLS frames use
      RFC 6587 octet-counting framing. TLS and plain TCP/UDP: syslog
      over UDP or unencrypted TCP is an explicit opt-in for lab
      environments. Facility defaults to Local0 (16).
    - SplunkHec: batches of HEC event envelopes posted to the
      /services/collector/event endpoint (sourcetype defaults to
      'bsn:audit', dotted lowercase like 'bsn:audit:session' is the
      recommended shape), optionally with indexed-field delivery
      confirmation (-Ack). HTTPS only - the token never travels over
      plain HTTP and is never logged. The token comes from -Token or the
      BSN_SPLUNK_HEC_TOKEN environment variable.
    - Transcript: the human-readable rendering of the same evidence
      (Start-Transcript-style txt with the Bsn audit frame), produced by
      ConvertTo-BsnTranscript -HeaderMode Bsn.

    Privacy: input records are opt-in (-IncludeInput - they contain
    everything typed, including secrets) and masked by a heuristic by
    default (-NoMaskSecrets disables it; never a guarantee - documented).
    Output records are opt-in (-IncludeOutput), ANSI-stripped and
    size-capped. Full-fidelity content stays in the cast; the log carries
    only capped, sanitized extracts.

    Evidence chain: pass -TranscriptPath on the NDJSON/Syslog/SplunkHec
    targets to embed transcript_sha256 in every record's evidence block,
    tying each SIEM hit to the machine-readable record, the bit-exact
    cast and the human-readable transcript.

.PARAMETER Path
    The asciicast v2 or v3 (.cast) file to export. Accepts pipeline
    input (also by the FullName property).

.PARAMETER Target
    The export target: NDJSON, Syslog, SplunkHec or Transcript.

.PARAMETER OutPath
    NDJSON/Transcript targets: the file to write. Accepts one cast at a
    time (a terminating error stops a pipeline that would overwrite the
    file repeatedly).

.PARAMETER Server
    Syslog target: the syslog server host name or address.

.PARAMETER Port
    Syslog target: the server port (default 6514, the conventional
    syslog-over-TLS port; plain TCP/UDP servers commonly use 514).

.PARAMETER Transport
    Syslog target: TLS (default), TCP or UDP.

.PARAMETER Facility
    Syslog target: RFC 5424 facility, Local0 (default) through Local7 -
    custom applications conventionally use local0-local7.

.PARAMETER StructuredDataId
    Syslog target: the private enterprise SD-ID of the structured data
    block. The default 'bsn@32473' is a placeholder - production
    deployments should register a free IANA Private Enterprise Number
    and pass their own id.

.PARAMETER Uri
    SplunkHec target: the HEC base URI, HTTPS only.

.PARAMETER Index
    SplunkHec target: the destination index (the token's default index
    applies when omitted).

.PARAMETER Sourcetype
    SplunkHec target: the sourcetype stamped on every event (default
    'bsn:audit').

.PARAMETER Token
    SplunkHec target: the HEC token. Falls back to the
    BSN_SPLUNK_HEC_TOKEN environment variable; the export fails when
    neither is set. The token is never logged.

.PARAMETER Ack
    SplunkHec target: verifies indexed-event delivery via the HEC
    acknowledgment endpoint (requires ack configured on the Splunk side).

.PARAMETER BatchSize
    SplunkHec target: events per HTTP request (default 50).

.PARAMETER IncludeInput
    Emits session_input records from recorded keystrokes (masked by
    default). Off by default: input contains everything typed.

.PARAMETER IncludeOutput
    Emits size-capped, ANSI-stripped session_output records. Off by
    default.

.PARAMETER NoMaskSecrets
    Disables the secret-masking heuristic on input records.

.PARAMETER OutputSizeCap
    Maximum characters of output text per record (default 512).

.PARAMETER SessionId
    Overrides the session id carried by every record (derived from the
    cast hash when omitted).

.PARAMETER ComputerName
    Fills the session host field of every record (blank by default).

.PARAMETER UserName
    Fills the session user field of every record (blank by default).

.PARAMETER Origin
    Fills the session origin field (default 'local').

.PARAMETER TranscriptPath
    NDJSON/Syslog/SplunkHec targets: a transcript file rendered from the
    same cast; its SHA-256 is embedded in every record's evidence block.

.INPUTS
    System.String
        The cast file path from the pipeline.

.OUTPUTS
    None

.EXAMPLE
    Export-BsnAuditLog -Path session01.cast -Target NDJSON -OutPath session01.ndjson

    Writes the local NDJSON audit log.

.EXAMPLE
    Export-BsnAuditLog -Path session01.cast -Target Syslog -Server log.example -Port 6514 -Transport TLS -Facility Local0

    Forwards the audit records to a TLS syslog collector with RFC 6587
    octet-counted framing.

.EXAMPLE
    Export-BsnAuditLog -Path session01.cast -Target SplunkHec -Uri https://splunk.example:8088 -Index audit -Sourcetype 'bsn:audit:session' -Token $token

    Posts batched HEC events to Splunk with indexed session fields.

.EXAMPLE
    Export-BsnAuditLog -Path session01.cast -Target Transcript -OutPath audit01.txt

    Writes the Start-Transcript-style audit transcript (the readable
    rendering of the same evidence).

.EXAMPLE
    Export-BsnAuditLog -Path session01.cast -Target Transcript -OutPath audit01.txt
    Export-BsnAuditLog -Path session01.cast -Target NDJSON -OutPath audit01.ndjson -TranscriptPath audit01.ndjson -TranscriptPath audit01.txt

    Produces the full evidence chain: every NDJSON record then carries
    transcript_sha256 alongside cast_sha256.

.EXAMPLE
    Export-BsnAuditLog -Path session01.cast -Target NDJSON -OutPath audit.ndjson -IncludeInput -WhatIf

    Previews the export without writing or sending anything
    (SupportsShouldProcess).

.NOTES
    Forwarder failures (unreachable syslog server, rejected HEC batch,
    failed acknowledgment) are terminating errors - an audit log that
    silently drops events would be worse than a loud failure.

.LINK
    https://bsvn.github.io/Lmt.Commons/en-US/Export-BsnAuditLog.html
#>
function Export-BsnAuditLog {
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'NDJSON')]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('FullName')]
        [string]$Path,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateSet('NDJSON', 'Syslog', 'SplunkHec', 'Transcript')]
        [string]$Target,

        [Parameter(Mandatory = $true, ParameterSetName = 'NDJSON')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Transcript')]
        [string]$OutPath,

        [Parameter(Mandatory = $true, ParameterSetName = 'Syslog')]
        [string]$Server,

        [Parameter(ParameterSetName = 'Syslog')]
        [ValidateRange(1, 65535)]
        [int]$Port = 6514,

        [Parameter(ParameterSetName = 'Syslog')]
        [ValidateSet('TLS', 'TCP', 'UDP')]
        [string]$Transport = 'TLS',

        [Parameter(ParameterSetName = 'Syslog')]
        [ValidateSet('Local0', 'Local1', 'Local2', 'Local3', 'Local4', 'Local5', 'Local6', 'Local7')]
        [string]$Facility = 'Local0',

        [Parameter(ParameterSetName = 'Syslog')]
        [string]$StructuredDataId = 'bsn@32473',

        [Parameter(Mandatory = $true, ParameterSetName = 'SplunkHec')]
        [string]$Uri,

        [Parameter(ParameterSetName = 'SplunkHec')]
        [string]$Index = '',

        [Parameter(ParameterSetName = 'SplunkHec')]
        [string]$Sourcetype = 'bsn:audit',

        [Parameter(ParameterSetName = 'SplunkHec')]
        [string]$Token = '',

        [Parameter(ParameterSetName = 'SplunkHec')]
        [switch]$Ack,

        [Parameter(ParameterSetName = 'SplunkHec')]
        [ValidateRange(1, 1000)]
        [int]$BatchSize = 50,

        [switch]$IncludeInput,

        [switch]$IncludeOutput,

        [switch]$NoMaskSecrets,

        [ValidateRange(64, 8192)]
        [int]$OutputSizeCap = 512,

        [string]$SessionId = '',

        [string]$ComputerName = '',

        [string]$UserName = '',

        [ValidateSet('local', 'ssh', 'console', 'remote')]
        [string]$Origin = 'local',

        [string]$TranscriptPath = ''
    )

    begin {
        $inputCount = 0
    }

    process {
        $inputCount++
        if (($inputCount -gt 1) -and (($PSCmdlet.ParameterSetName -eq 'NDJSON') -or ($PSCmdlet.ParameterSetName -eq 'Transcript'))) {
            throw '-OutPath exports a single cast file, but the pipeline supplied another one. Drop -OutPath or convert one cast at a time.'
        }

        $operationDescription = switch ($Target) {
            'NDJSON' { "write the NDJSON audit log to '{0}'" -f $OutPath }
            'Transcript' { "write the audit transcript to '{0}'" -f $OutPath }
            'Syslog' { "forward the audit log to syslog server '{0}' over {1} on port {2}" -f $Server, $Transport, $Port }
            'SplunkHec' { "forward the audit log to the Splunk HEC at '{0}'" -f $Uri }
        }
        if (-not $PSCmdlet.ShouldProcess($Path, $operationDescription)) {
            return
        }

        if ($Target -eq 'Transcript') {
            $transcriptParameters = @{
                Path = $Path
                OutPath = $OutPath
                HeaderMode = 'Bsn'
            }
            if ($SessionId) { $transcriptParameters.SessionId = $SessionId }
            if ($UserName) { $transcriptParameters.Username = $UserName }
            if ($ComputerName) { $transcriptParameters.Machine = $ComputerName }
            ConvertTo-BsnTranscript @transcriptParameters
            return
        }

        $recordParameters = @{
            Path = $Path
            IncludeInput = $IncludeInput.IsPresent
            IncludeOutput = $IncludeOutput.IsPresent
            NoMaskSecrets = $NoMaskSecrets.IsPresent
            OutputSizeCap = $OutputSizeCap
            SessionId = $SessionId
            ComputerName = $ComputerName
            UserName = $UserName
            Origin = $Origin
            TranscriptPath = $TranscriptPath
        }
        $records = @(ConvertTo-BsnAuditRecord @recordParameters)

        if ($Target -eq 'NDJSON') {
            $writer = [System.IO.StreamWriter]::new($OutPath, $false, [System.Text.UTF8Encoding]::new($false))
            $writer.NewLine = "`n"
            try {
                foreach ($record in $records) {
                    $recordJson = ConvertTo-Json -InputObject $record -Compress -Depth 6
                    $writer.WriteLine($recordJson)
                }
            }
            finally {
                $writer.Dispose()
            }
            return
        }

        if ($Target -eq 'Syslog') {
            $facilityNumbers = @{
                Local0 = 16
                Local1 = 17
                Local2 = 18
                Local3 = 19
                Local4 = 20
                Local5 = 21
                Local6 = 22
                Local7 = 23
            }
            $frames = @($records | ForEach-Object -Process {
                ConvertTo-BsnSyslogMessage -Record $_ -FacilityNumber $facilityNumbers[$Facility] -StructuredDataId $StructuredDataId
            })
            Send-BsnAuditSyslog -Frames $frames -Server $Server -Port $Port -Transport $Transport
            return
        }

        # SplunkHec target.
        $hecToken = $Token
        if (-not $hecToken) {
            $hecToken = $env:BSN_SPLUNK_HEC_TOKEN
        }
        if (-not $hecToken) {
            throw 'No Splunk HEC token: pass -Token or set the BSN_SPLUNK_HEC_TOKEN environment variable.'
        }
        if (-not $Uri.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw ('The Splunk HEC endpoint must use HTTPS (got ''{0}''). The token is never sent over plain HTTP.' -f $Uri)
        }

        $envelopes = @($records | ForEach-Object -Process {
            ConvertTo-BsnSplunkEvent -Record $_ -Sourcetype $Sourcetype -Index $Index
        })
        $payloads = for ($batchStart = 0; $batchStart -lt $envelopes.Count; $batchStart += $BatchSize) {
            $batchEnd = [math]::Min($batchStart + $BatchSize - 1, $envelopes.Count - 1)
            ($envelopes[$batchStart..$batchEnd] -join "`n")
        }

        $channelId = [guid]::NewGuid().ToString()
        Send-BsnSplunkHec -Payloads @($payloads) -Uri $Uri -Token $hecToken -ChannelId $channelId -Ack:$Ack.IsPresent
    }
}
