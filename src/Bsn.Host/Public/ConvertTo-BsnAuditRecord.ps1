<#
.SYNOPSIS
    Converts an asciicast (.cast) recording into canonical audit records.

.DESCRIPTION
    Pure converter (no console replay, no network): reads the cast
    timeline through the shared Get-BsnCastTimeline parser and emits one
    structured record per event of the audit taxonomy - the machine-
    readable index of the recorded evidence ("the log is the index, the
    cast is the evidence"):

    | event.type      | Source in cast                                  |
    | --------------- | ----------------------------------------------- |
    | session_open    | cast header (session context, terminal size)    |
    | session_input   | 'i' events - opt-in via -IncludeInput           |
    | session_output  | 'o' events - opt-in via -IncludeOutput          |
    | session_resize  | 'r' events (debug level)                        |
    | session_marker  | 'm' events (notice level)                       |
    | session_close   | end of timeline (duration, bytes, exit code)    |
    | session_summary | derived counts and hashes - always emitted      |

    Record shape (schema 'bsn.audit/1', JSON-serializable PSCustomObject
    with stable property order):

    - time: RFC 3339 UTC with fractional seconds, computed from the cast
      header timestamp plus the event's offset (casts store relative
      times only).
    - event: { kind, type, outcome }; severity: notice/info/debug name.
    - session: { id, recorded_by, host, user, shell, command, origin }.
      Host and user are not recorded inside a cast and are blank unless
      supplied via -ComputerName / -UserName; shell and command come from
      the cast header. id defaults to 'bsn-' plus the first twelve hex
      characters of the cast SHA-256 and can be overridden.
    - position: { offset_ms, event_index, stream } - any SIEM hit can be
      replayed bit-exact from the cast (event_index + offset).
    - input / output / resize / marker blocks carry capped, sanitized
      extracts: input is opt-in (it contains everything typed, including
      secrets) and passes through the -MaskSecrets heuristic by default
      (never a guarantee - documented); output is ANSI-stripped and
      size-capped.
    - evidence: { cast_path, cast_sha256, cast_bytes, transcript_sha256 }
      - the transcript hash is included when -TranscriptPath points at
      the readable rendering (Export-BsnAuditLog -Target Transcript /
      ConvertTo-BsnTranscript), tying the SIEM record to both the exact
      replay and the human-readable txt.

    Use Export-BsnAuditLog to render these records to NDJSON, syslog
    (RFC 5424), Splunk HEC or the audit transcript.

.PARAMETER Path
    The asciicast v2 or v3 (.cast) file to convert. Accepts pipeline
    input (also by the FullName property).

.PARAMETER IncludeInput
    Emits session_input records from recorded keystroke ('i') events.
    Off by default: input contains everything typed, including secrets.

.PARAMETER IncludeOutput
    Emits session_output records from output ('o') events. Off by
    default (too noisy for SIEMs); emitted text is ANSI-stripped and
    carriage-return overtype-resolved, capped by -OutputSizeCap.

.PARAMETER NoMaskSecrets
    Disables the -MaskSecrets heuristic on input records. The heuristic
    replaces values after key-like words (password=..., token: ...,
    api key ...) with '***' and is applied by default; it is never a
    guarantee - secrets typed at hidden prompts are undetectable.

.PARAMETER OutputSizeCap
    Maximum characters of output text per session_output record
    (default 512); longer extracts are truncated and flagged.

.PARAMETER SessionId
    Overrides the session id. Derived from the cast hash when omitted.

.PARAMETER ComputerName
    Overrides the session host field. Blank by default: casts do not
    record the machine they were captured on - recordings made by
    Start-InteractiveTranscript carry it in the header's capture-time
    bsn metadata block, which this converter reads automatically.

.PARAMETER UserName
    Overrides the session user field. Recordings made by
    Start-InteractiveTranscript carry the user in the header's
    capture-time bsn metadata block, which this converter reads
    automatically.

.PARAMETER Origin
    Fills the session origin field (default 'local').

.PARAMETER TranscriptPath
    A transcript file rendered from the same cast (ConvertTo-BsnTranscript
    or Export-BsnAuditLog -Target Transcript). Its SHA-256 is embedded in
    every record's evidence block as transcript_sha256.

.INPUTS
    System.String
        The cast file path from the pipeline.

.OUTPUTS
    System.Management.Automation.PSCustomObject
        One canonical audit record per taxonomy event.

.EXAMPLE
    ConvertTo-BsnAuditRecord -Path session01.cast

    Emits the default taxonomy: session_open, session_close and
    session_summary (input/output events suppressed).

.EXAMPLE
    ConvertTo-BsnAuditRecord session01.cast -IncludeInput -ComputerName ws01 -UserName jdoe

    Includes typed-input records (masked by default) and fills the
    session context a cast cannot carry.

.EXAMPLE
    ConvertTo-BsnAuditRecord session01.cast -IncludeOutput -OutputSizeCap 256

    Includes size-capped, ANSI-stripped output extracts.

.EXAMPLE
    ConvertTo-BsnAuditRecord session01.cast -TranscriptPath session01.txt | ConvertTo-Json

    Emits records whose evidence block ties the cast to its transcript.

.NOTES
    Severity mapping: session_open/close + markers = notice, input/output
    = info, resize = debug; the syslog exporter maps these to RFC 5424
    PRI values (facility * 8 + severity).

.LINK
    https://bsvn.github.io/Lmt.Commons/en-US/ConvertTo-BsnAuditRecord.html
#>
function ConvertTo-BsnAuditRecord {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('FullName')]
        [string]$Path,

        [switch]$IncludeInput,

        [switch]$IncludeOutput,

        [switch]$NoMaskSecrets,

        [ValidateRange(1, 8192)]
        [int]$OutputSizeCap = 512,

        [string]$SessionId = '',

        [string]$ComputerName = '',

        [string]$UserName = '',

        [ValidateSet('local', 'ssh', 'console', 'remote')]
        [string]$Origin = 'local',

        [string]$TranscriptPath = ''
    )

    process {
        # Same pure parser every cast consumer shares - no re-parsing here.
        $timeline = Get-BsnCastTimeline -Path $Path
        $resolvedCastPath = (Resolve-Path -LiteralPath $Path).ProviderPath

        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $transcriptHashBytes = $null
        try {
            $castFileBytes = [System.IO.File]::ReadAllBytes($resolvedCastPath)
            $castHashBytes = $sha256.ComputeHash($castFileBytes)
            if ($TranscriptPath) {
                $resolvedTranscriptPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TranscriptPath)
                if (-not (Test-Path -LiteralPath $resolvedTranscriptPath -PathType Leaf)) {
                    throw ("The transcript file '{0}' does not exist. Render it first with Export-BsnAuditLog -Target Transcript or ConvertTo-BsnTranscript." -f $resolvedTranscriptPath)
                }
                $transcriptHashBytes = $sha256.ComputeHash([System.IO.File]::ReadAllBytes($resolvedTranscriptPath))
            }
        }
        finally {
            $sha256.Dispose()
        }
        $castHash = [System.BitConverter]::ToString($castHashBytes).Replace('-', '').ToLowerInvariant()
        $transcriptHash = $null
        if ($transcriptHashBytes) {
            $transcriptHash = [System.BitConverter]::ToString($transcriptHashBytes).Replace('-', '').ToLowerInvariant()
        }

        # --- cast header fields -------------------------------------------------
        # Every key except 'version' is optional; probe instead of referencing
        # so recorder-side metadata additions cannot break the conversion.
        $timestampValue = Get-BsnObjectProperty -Object $timeline.Header -Name 'timestamp'
        $startEpoch = if ($null -ne $timestampValue) { [long]$timestampValue } else { 0 }
        $epochStart = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
        $rfc3339Format = "yyyy-MM-dd'T'HH:mm:ss.ffffff'Z'"
        $invariantCulture = [System.Globalization.CultureInfo]::InvariantCulture

        $commandValue = Get-BsnObjectProperty -Object $timeline.Header -Name 'command'
        $environmentValue = Get-BsnObjectProperty -Object $timeline.Header -Name 'env'
        $shellName = ''
        if ($null -ne $environmentValue) {
            $shellValue = Get-BsnObjectProperty -Object $environmentValue -Name 'SHELL'
            if ($null -ne $shellValue) {
                $shellName = [string]$shellValue
            }
        }

        # Terminal size: v2 carries width/height, v3 a term object.
        $widthValue = Get-BsnObjectProperty -Object $timeline.Header -Name 'width'
        $heightValue = Get-BsnObjectProperty -Object $timeline.Header -Name 'height'
        $columns = 0
        $rows = 0
        if (($null -ne $widthValue) -and ($null -ne $heightValue)) {
            $columns = [int]$widthValue
            $rows = [int]$heightValue
        }
        else {
            $termValue = Get-BsnObjectProperty -Object $timeline.Header -Name 'term'
            if ($null -ne $termValue) {
                $colsValue = Get-BsnObjectProperty -Object $termValue -Name 'cols'
                $rowsValue = Get-BsnObjectProperty -Object $termValue -Name 'rows'
                if (($null -ne $colsValue) -and ($null -ne $rowsValue)) {
                    $columns = [int]$colsValue
                    $rows = [int]$rowsValue
                }
            }
        }

        # session context resolution: explicit parameters first (SIEM
        # normalization), then the capture-time bsn metadata block stamped
        # by Start-InteractiveTranscript, then blank/derived.
        $bsnBlock = Get-BsnObjectProperty -Object $timeline.Header -Name 'bsn'
        $bsnHost = ''
        $bsnUser = ''
        $bsnRecordedBy = ''
        $bsnSessionId = ''
        if ($null -ne $bsnBlock) {
            $probeValue = Get-BsnObjectProperty -Object $bsnBlock -Name 'host'
            if ($null -ne $probeValue) { $bsnHost = [string]$probeValue }
            $probeValue = Get-BsnObjectProperty -Object $bsnBlock -Name 'user'
            if ($null -ne $probeValue) { $bsnUser = [string]$probeValue }
            $probeValue = Get-BsnObjectProperty -Object $bsnBlock -Name 'recorded_by'
            if ($null -ne $probeValue) { $bsnRecordedBy = [string]$probeValue }
            $probeValue = Get-BsnObjectProperty -Object $bsnBlock -Name 'session_id'
            if ($null -ne $probeValue) { $bsnSessionId = [string]$probeValue }
        }

        $sessionHost = if ($ComputerName) { $ComputerName } else { $bsnHost }
        $sessionUser = if ($UserName) { $UserName } else { $bsnUser }
        $sessionIdText = if ($SessionId) {
            $SessionId
        }
        elseif ($bsnSessionId) {
            $bsnSessionId
        }
        else {
            'bsn-' + $castHash.Substring(0, 12)
        }

        # recorded_by prefers the version that made the recording (capture
        # time bsn block) over the version doing the conversion.
        $owningModule = $MyInvocation.MyCommand.ScriptBlock.Module
        $recordedBy = $bsnRecordedBy
        if (-not $recordedBy) {
            $recordedBy = 'bsn.host'
            if ($owningModule -and $owningModule.Version) {
                $recordedBy = 'bsn.host {0}' -f $owningModule.Version
            }
        }

        # session_open: absolute recording start, full session context.
        [pscustomobject]@{
            schema = 'bsn.audit/1'
            time = $epochStart.AddSeconds($startEpoch).ToString($rfc3339Format, $invariantCulture)
            event = [pscustomobject]@{ kind = 'session_activity'; type = 'session_open'; outcome = 'success' }
            severity = 'notice'
            session = [pscustomobject]@{
                id = $sessionIdText
                recorded_by = $recordedBy
                host = $sessionHost
                user = $sessionUser
                shell = $shellName
                command = [string]$commandValue
                origin = $Origin
            }
            position = [pscustomobject]@{ offset_ms = 0; event_index = 0; stream = 'meta' }
            terminal = [pscustomobject]@{ columns = $columns; rows = $rows }
            evidence = [pscustomobject]@{
                cast_path = $resolvedCastPath
                cast_sha256 = $castHash
                cast_bytes = $castFileBytes.Length
                transcript_sha256 = $transcriptHash
            }
        }

        # --- timeline events ------------------------------------------------
        $utf8 = [System.Text.Encoding]::UTF8
        $inputBytes = 0
        $outputBytes = 0
        $inputRecordCount = 0
        $outputRecordCount = 0
        $resizeCount = 0
        $markerCount = 0
        $exitCode = $null
        $lastEventSeconds = 0.0
        $lastEventIndex = 0
        $currentIndex = 0

        foreach ($timelineEvent in $timeline.Events) {
            $currentIndex++
            $eventSeconds = [double]$timelineEvent[0]
            $offsetMs = [int][math]::Round($eventSeconds * 1000)
            $eventType = [string]$timelineEvent[1]
            $eventTime = $epochStart.AddSeconds($startEpoch + $eventSeconds).ToString($rfc3339Format, $invariantCulture)
            $lastEventSeconds = $eventSeconds
            $lastEventIndex = $currentIndex

            if ($eventType -eq 'i') {
                $inputBytes += $utf8.GetByteCount([string]$timelineEvent[2])
                if (-not $IncludeInput) { continue }

                $inputRecordCount++
                $inputText = [string]$timelineEvent[2]
                $masked = $false
                if (-not $NoMaskSecrets) {
                    $inputText = Hide-BsnAuditSecret -Text $inputText
                    $masked = $true
                }

                [pscustomobject]@{
                    schema = 'bsn.audit/1'
                    time = $eventTime
                    event = [pscustomobject]@{ kind = 'session_activity'; type = 'session_input'; outcome = 'success' }
                    severity = 'info'
                    session = [pscustomobject]@{
                        id = $sessionIdText
                        recorded_by = $recordedBy
                        host = $sessionHost
                        user = $sessionUser
                        shell = $shellName
                        command = [string]$commandValue
                        origin = $Origin
                    }
                    position = [pscustomobject]@{ offset_ms = $offsetMs; event_index = $currentIndex; stream = 'input' }
                    input = [pscustomobject]@{ text = $inputText; masked = $masked }
                    evidence = [pscustomobject]@{
                        cast_path = $resolvedCastPath
                        cast_sha256 = $castHash
                        cast_bytes = $castFileBytes.Length
                        transcript_sha256 = $transcriptHash
                    }
                }
            }
            elseif ($eventType -eq 'o') {
                $outputBytes += $utf8.GetByteCount([string]$timelineEvent[2])
                if (-not $IncludeOutput) { continue }

                $outputRecordCount++
                $outputText = ConvertTo-BsnPlainText -Text ([string]$timelineEvent[2])
                $truncated = $false
                if ($outputText.Length -gt $OutputSizeCap) {
                    $outputText = $outputText.Substring(0, $OutputSizeCap)
                    $truncated = $true
                }

                [pscustomobject]@{
                    schema = 'bsn.audit/1'
                    time = $eventTime
                    event = [pscustomobject]@{ kind = 'session_activity'; type = 'session_output'; outcome = 'success' }
                    severity = 'info'
                    session = [pscustomobject]@{
                        id = $sessionIdText
                        recorded_by = $recordedBy
                        host = $sessionHost
                        user = $sessionUser
                        shell = $shellName
                        command = [string]$commandValue
                        origin = $Origin
                    }
                    position = [pscustomobject]@{ offset_ms = $offsetMs; event_index = $currentIndex; stream = 'output' }
                    output = [pscustomobject]@{ text = $outputText; truncated = $truncated }
                    evidence = [pscustomobject]@{
                        cast_path = $resolvedCastPath
                        cast_sha256 = $castHash
                        cast_bytes = $castFileBytes.Length
                        transcript_sha256 = $transcriptHash
                    }
                }
            }
            elseif ($eventType -eq 'r') {
                $resizeCount++
                $resizeColumns = $columns
                $resizeRows = $rows
                $sizeMatch = [regex]::Match([string]$timelineEvent[2], '^\s*(\d+)x(\d+)\s*$')
                if ($sizeMatch.Success) {
                    $resizeColumns = [int]$sizeMatch.Groups[1].Value
                    $resizeRows = [int]$sizeMatch.Groups[2].Value
                }

                [pscustomobject]@{
                    schema = 'bsn.audit/1'
                    time = $eventTime
                    event = [pscustomobject]@{ kind = 'session_activity'; type = 'session_resize'; outcome = 'success' }
                    severity = 'debug'
                    session = [pscustomobject]@{
                        id = $sessionIdText
                        recorded_by = $recordedBy
                        host = $sessionHost
                        user = $sessionUser
                        shell = $shellName
                        command = [string]$commandValue
                        origin = $Origin
                    }
                    position = [pscustomobject]@{ offset_ms = $offsetMs; event_index = $currentIndex; stream = 'control' }
                    resize = [pscustomobject]@{ columns = $resizeColumns; rows = $resizeRows }
                    evidence = [pscustomobject]@{
                        cast_path = $resolvedCastPath
                        cast_sha256 = $castHash
                        cast_bytes = $castFileBytes.Length
                        transcript_sha256 = $transcriptHash
                    }
                }
            }
            elseif ($eventType -eq 'm') {
                $markerCount++
                [pscustomobject]@{
                    schema = 'bsn.audit/1'
                    time = $eventTime
                    event = [pscustomobject]@{ kind = 'session_activity'; type = 'session_marker'; outcome = 'success' }
                    severity = 'notice'
                    session = [pscustomobject]@{
                        id = $sessionIdText
                        recorded_by = $recordedBy
                        host = $sessionHost
                        user = $sessionUser
                        shell = $shellName
                        command = [string]$commandValue
                        origin = $Origin
                    }
                    position = [pscustomobject]@{ offset_ms = $offsetMs; event_index = $currentIndex; stream = 'marker' }
                    marker = [pscustomobject]@{ label = [string]$timelineEvent[2] }
                    evidence = [pscustomobject]@{
                        cast_path = $resolvedCastPath
                        cast_sha256 = $castHash
                        cast_bytes = $castFileBytes.Length
                        transcript_sha256 = $transcriptHash
                    }
                }
            }
            elseif ($eventType -eq 'x') {
                # v3 exit-status event: surfaced in session_close/summary.
                $exitCode = [string]$timelineEvent[2]
            }
        }

        # --- session close + summary -------------------------------------------
        $durationMs = [int][math]::Round($lastEventSeconds * 1000)
        $exitCodeValue = $null
        if ($null -ne $exitCode) {
            $parsedExitCode = 0
            if ([int]::TryParse($exitCode, [ref]$parsedExitCode)) {
                $exitCodeValue = $parsedExitCode
            }
        }

        $closePosition = [pscustomobject]@{ offset_ms = $durationMs; event_index = $lastEventIndex; stream = 'meta' }
        $evidenceBlock = [pscustomobject]@{
            cast_path = $resolvedCastPath
            cast_sha256 = $castHash
            cast_bytes = $castFileBytes.Length
            transcript_sha256 = $transcriptHash
        }

        [pscustomobject]@{
            schema = 'bsn.audit/1'
            time = $epochStart.AddSeconds($lastEventSeconds).ToString($rfc3339Format, $invariantCulture)
            event = [pscustomobject]@{ kind = 'session_activity'; type = 'session_close'; outcome = 'success' }
            severity = 'notice'
            session = [pscustomobject]@{
                id = $sessionIdText
                recorded_by = $recordedBy
                host = $sessionHost
                user = $sessionUser
                shell = $shellName
                command = [string]$commandValue
                origin = $Origin
            }
            position = $closePosition
            close = [pscustomobject]@{
                duration_ms = $durationMs
                input_bytes = $inputBytes
                output_bytes = $outputBytes
                exit_code = $exitCodeValue
            }
            evidence = $evidenceBlock
        }

        [pscustomobject]@{
            schema = 'bsn.audit/1'
            time = $epochStart.AddSeconds($lastEventSeconds).ToString($rfc3339Format, $invariantCulture)
            event = [pscustomobject]@{ kind = 'session_activity'; type = 'session_summary'; outcome = 'success' }
            severity = 'notice'
            session = [pscustomobject]@{
                id = $sessionIdText
                recorded_by = $recordedBy
                host = $sessionHost
                user = $sessionUser
                shell = $shellName
                command = [string]$commandValue
                origin = $Origin
            }
            position = $closePosition
            summary = [pscustomobject]@{
                duration_ms = $durationMs
                input_bytes = $inputBytes
                output_bytes = $outputBytes
                exit_code = $exitCodeValue
                events = [pscustomobject]@{
                    input = $inputRecordCount
                    output = $outputRecordCount
                    resize = $resizeCount
                    marker = $markerCount
                }
            }
            evidence = $evidenceBlock
        }
    }
}
