[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingComputerNameHardcoded', '', Justification = 'Test fixtures use synthetic computer names.')]
param()

BeforeAll {
    $moduleRoot = Split-Path -Parent -Path (Split-Path -Parent -Path $PSScriptRoot)
    # Make the repo sibling module Bsn.Common resolvable for RequiredModules validation.
    $env:PSModulePath = '{0}{1}{2}' -f (Split-Path -Parent -Path $moduleRoot), [System.IO.Path]::PathSeparator, $env:PSModulePath
    $manifestPath = Join-Path -Path $moduleRoot -ChildPath 'Bsn.Host.psd1'
    try {
        Import-Module -Name $manifestPath -Force -ErrorAction 'Stop'
    }
    catch [System.IO.FileLoadException] {
        Import-Module -Name (Join-Path $moduleRoot 'Bsn.Host.psm1') -Force -ErrorAction 'Stop'
    }

    function Get-BsnTestFileHash {
        param([string]$File)
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            return [System.BitConverter]::ToString($sha256.ComputeHash([System.IO.File]::ReadAllBytes($File))).Replace('-', '').ToLowerInvariant()
        }
        finally {
            $sha256.Dispose()
        }
    }

    # A cast producing 6 audit records with IncludeInput/IncludeOutput:
    # open, input, output, marker, close, summary.
    $script:ExportCastPath = Join-Path -Path $TestDrive -ChildPath 'export.cast'
    $lines = @(
        '{"version": 2, "width": 80, "height": 24, "timestamp": 1793895000, "env": {"SHELL": "pwsh", "TERM": "xterm-256color"}}'
        ('[0.1, "o", {0}]' -f ('PS> echo hi' + "`r`n" | ConvertTo-Json -Compress))
        ('[0.4, "i", {0}]' -f ('echo hi' + "`r" | ConvertTo-Json -Compress))
        ('[0.6, "m", {0}]' -f ('done' | ConvertTo-Json -Compress))
    )
    Set-Content -LiteralPath $script:ExportCastPath -Value ($lines -join "`n") -NoNewline
}

Describe 'ConvertTo-BsnSyslogMessage' {
    BeforeAll {
        $script:InfoRecord = ConvertTo-BsnAuditRecord -Path $script:ExportCastPath -IncludeInput -ComputerName 'ws01' |
            Where-Object { $_.event.type -eq 'session_input' }
        $script:OpenRecord = ConvertTo-BsnAuditRecord -Path $script:ExportCastPath |
            Select-Object -First 1
    }

    It 'computes the RFC 5424 PRI from facility and severity (local0.info = 134)' {
        $line = & (Get-Module -Name 'Bsn.Host') { param($r) ConvertTo-BsnSyslogMessage -Record $r -FacilityNumber 16 } $script:InfoRecord
        $line | Should -BeLike '<134>1 *'
    }

    It 'maps the notice severity of session_open (local0.notice = 133)' {
        $line = & (Get-Module -Name 'Bsn.Host') { param($r) ConvertTo-BsnSyslogMessage -Record $r -FacilityNumber 16 } $script:OpenRecord
        $line | Should -BeLike '<133>1 *'
    }

    It 'adds the facility offset for Local3 (19 * 8 + 6 = 158)' {
        $line = & (Get-Module -Name 'Bsn.Host') { param($r) ConvertTo-BsnSyslogMessage -Record $r -FacilityNumber 19 } $script:InfoRecord
        $line | Should -BeLike '<158>1 *'
    }

    It 'uses the session host, app-name bsn.host, session-id PROCID and BSN_<TYPE> MSGID' {
        $line = & (Get-Module -Name 'Bsn.Host') { param($r) ConvertTo-BsnSyslogMessage -Record $r -FacilityNumber 16 } $script:InfoRecord
        $fields = $line -split ' '
        $fields[1] | Should -Be $script:InfoRecord.time
        $fields[2] | Should -Be 'ws01'
        $fields[3] | Should -Be 'bsn.host'
        $fields[4] | Should -Be $script:InfoRecord.session.id
        $fields[5] | Should -Be 'BSN_SESSION_INPUT'
    }

    It 'falls back to the NILVALUE host when the recorded host is unknown' {
        $record = ConvertTo-BsnAuditRecord -Path $script:ExportCastPath | Select-Object -First 1
        $line = & (Get-Module -Name 'Bsn.Host') { param($r) ConvertTo-BsnSyslogMessage -Record $r -FacilityNumber 16 } $record
        ($line -split ' ')[2] | Should -Be '-'
    }

    It 'carries the correlation structured data and the canonical JSON message' {
        $line = & (Get-Module -Name 'Bsn.Host') { param($r) ConvertTo-BsnSyslogMessage -Record $r -FacilityNumber 16 } $script:InfoRecord
        $expectedStructuredData = ('[bsn@32473 session_id="{0}" cast_sha256="{1}" offset_ms="400"]' -f $script:InfoRecord.session.id, $script:InfoRecord.evidence.cast_sha256)
        $line.Contains($expectedStructuredData) | Should -BeTrue
        $line.Contains('"schema":"bsn.audit/1"') | Should -BeTrue
    }

    It 'escapes RFC 5424 special characters in structured-data values' {
        $record = ConvertTo-BsnAuditRecord -Path $script:ExportCastPath -SessionId 'a"b\c]d' | Select-Object -First 1
        $line = & (Get-Module -Name 'Bsn.Host') { param($r) ConvertTo-BsnSyslogMessage -Record $r -FacilityNumber 16 } $record
        $line.Contains('session_id="a\"b\\c\]d"') | Should -BeTrue
    }

    It 'falls back to info severity for unknown severity names (PRI = facility * 8 + 6)' {
        $bogusRecord = ConvertTo-BsnAuditRecord -Path $script:ExportCastPath | Select-Object -First 1
        $bogusRecord.severity = 'bogus'
        $line = & (Get-Module -Name 'Bsn.Host') { param($r) ConvertTo-BsnSyslogMessage -Record $r -FacilityNumber 16 } $bogusRecord
        $line | Should -BeLike '<134>1 *'
    }

    It 'accepts a custom structured data id (registered IANA enterprise number)' {
        $line = & (Get-Module -Name 'Bsn.Host') { param($r) ConvertTo-BsnSyslogMessage -Record $r -FacilityNumber 16 -StructuredDataId 'bsn@99999' } $script:OpenRecord
        $line.Contains('[bsn@99999 ') | Should -BeTrue
    }
}

Describe 'ConvertTo-BsnSplunkEvent' {
    BeforeAll {
        $script:Record = ConvertTo-BsnAuditRecord -Path $script:ExportCastPath -ComputerName 'ws01' |
            Where-Object { $_.event.type -eq 'session_marker' }
    }

    It 'wraps the canonical record with time, host, source, sourcetype and fields' {
        $envelopeJson = & (Get-Module -Name 'Bsn.Host') { param($r) ConvertTo-BsnSplunkEvent -Record $r } $script:Record
        $envelope = $envelopeJson | ConvertFrom-Json
        $envelope.time | Should -Be 1793895000.6
        $envelope.host | Should -Be 'ws01'
        $envelope.source | Should -Be 'bsn.host'
        $envelope.sourcetype | Should -Be 'bsn:audit'
        $envelope.event.schema | Should -Be 'bsn.audit/1'
        $envelope.fields.session_id | Should -Be $script:Record.session.id
        $envelope.fields.event_type | Should -Be 'session_marker'
        $envelope.fields.cast_sha256 | Should -Be $script:Record.evidence.cast_sha256
    }

    It 'omits index and host when unknown, includes them when supplied' {
        $defaultJson = & (Get-Module -Name 'Bsn.Host') { param($r) ConvertTo-BsnSplunkEvent -Record $r } (ConvertTo-BsnAuditRecord -Path $script:ExportCastPath | Select-Object -First 1)
        $default = $defaultJson | ConvertFrom-Json
        $default.PSObject.Properties['index'] | Should -BeNullOrEmpty
        $default.PSObject.Properties['host'] | Should -BeNullOrEmpty

        $customJson = & (Get-Module -Name 'Bsn.Host') { param($r) ConvertTo-BsnSplunkEvent -Record $r -Index 'audit' -Sourcetype 'bsn:audit:session' } $script:Record
        $custom = $customJson | ConvertFrom-Json
        $custom.index | Should -Be 'audit'
        $custom.sourcetype | Should -Be 'bsn:audit:session'
    }
}

Describe 'Export-BsnAuditLog -Target NDJSON' {
    It 'writes one canonical JSON record per line as UTF-8 without BOM with LF endings' {
        $outPath = Join-Path -Path $TestDrive -ChildPath 'audit.ndjson'
        Export-BsnAuditLog -Path $script:ExportCastPath -Target NDJSON -OutPath $outPath -IncludeInput -IncludeOutput

        $bytes = [System.IO.File]::ReadAllBytes($outPath)
        $bytes[0] | Should -Not -Be 0xEF

        $content = [System.IO.File]::ReadAllText($outPath, [System.Text.Encoding]::UTF8)
        $content.Contains("`r") | Should -BeFalse -Because 'NDJSON line endings must be bare LF'

        $logLines = @($content.TrimEnd("`n") -split "`n")
        $logLines.Count | Should -Be 6
        ($logLines | ForEach-Object { ($_ | ConvertFrom-Json).schema } | Select-Object -Unique) | Should -Be 'bsn.audit/1'
        @($logLines | ForEach-Object { ($_ | ConvertFrom-Json).event.type }) |
            Should -Be @('session_open', 'session_output', 'session_input', 'session_marker', 'session_close', 'session_summary')
    }

    It 'supports -WhatIf without writing anything' {
        $outPath = Join-Path -Path $TestDrive -ChildPath 'whatif.ndjson'
        Export-BsnAuditLog -Path $script:ExportCastPath -Target NDJSON -OutPath $outPath -WhatIf
        Test-Path -LiteralPath $outPath | Should -BeFalse
    }

    It 'rejects more than one pipeline input when -OutPath is used' {
        {
            @($script:ExportCastPath, $script:ExportCastPath) |
                Export-BsnAuditLog -Target NDJSON -OutPath (Join-Path -Path $TestDrive -ChildPath 'multi.ndjson')
        } | Should -Throw '*exports a single cast file*'
    }

    It 'embeds transcript_sha256 when -TranscriptPath is supplied' {
        $transcriptPath = Join-Path -Path $TestDrive -ChildPath 'linked.txt'
        Set-Content -LiteralPath $transcriptPath -Value 'rendering' -NoNewline
        $outPath = Join-Path -Path $TestDrive -ChildPath 'linked.ndjson'
        Export-BsnAuditLog -Path $script:ExportCastPath -Target NDJSON -OutPath $outPath -TranscriptPath $transcriptPath

        $firstLine = (Get-Content -LiteralPath $outPath -TotalCount 1) | ConvertFrom-Json
        $firstLine.evidence.transcript_sha256 | Should -Be (Get-BsnTestFileHash -File $transcriptPath)
    }
}

Describe 'Export-BsnAuditLog -Target Transcript' {
    It 'writes the audit-framed transcript (ConvertTo-BsnTranscript -HeaderMode Bsn)' {
        $outPath = Join-Path -Path $TestDrive -ChildPath 'audit.txt'
        Export-BsnAuditLog -Path $script:ExportCastPath -Target Transcript -OutPath $outPath `
            -SessionId 'audit-42' -UserName 'CONTOSO\jdoe' -ComputerName 'ws01'

        # The direct call writes to a differently named file, and the
        # 'Transcript started, output file is ...' line embeds that path -
        # normalize it away before comparing everything else byte-for-byte.
        $directPath = Join-Path -Path $TestDrive -ChildPath 'direct.txt'
        ConvertTo-BsnTranscript -Path $script:ExportCastPath -HeaderMode Bsn -OutPath $directPath `
            -SessionId 'audit-42' -Username 'CONTOSO\jdoe' -Machine 'ws01'

        $exportContent = [System.IO.File]::ReadAllText($outPath, [System.Text.Encoding]::UTF8)
        $directContent = [System.IO.File]::ReadAllText($directPath, [System.Text.Encoding]::UTF8)
        $normalizedDirect = $directContent.Replace($directPath, $outPath)
        $exportContent | Should -BeExactly $normalizedDirect
        $exportContent.Contains('Session Id: audit-42') | Should -BeTrue
        $exportContent.Contains('Username: CONTOSO\jdoe') | Should -BeTrue
        $exportContent.Contains('Machine: ws01') | Should -BeTrue
    }
}

Describe 'Export-BsnAuditLog -Target Syslog' {
    It 'sends RFC 5424 frames over TLS by default' {
        $script:syslogCapture = $null
        Mock Send-BsnAuditSyslog -ModuleName Bsn.Host -MockWith {
            param($Frames, $Server, $Port, $Transport)
            $script:syslogCapture = @{
                Frames = @($Frames)
                Server = $Server
                Port = $Port
                Transport = $Transport
            }
        }

        # Timeline order: output (0.1), input (0.4), marker (0.6).
        Export-BsnAuditLog -Path $script:ExportCastPath -Target Syslog -Server 'log.example' -IncludeInput -IncludeOutput

        $script:syslogCapture.Server | Should -Be 'log.example'
        $script:syslogCapture.Port | Should -Be 6514
        $script:syslogCapture.Transport | Should -Be 'TLS'
        $script:syslogCapture.Frames.Count | Should -Be 6
        $script:syslogCapture.Frames[0] | Should -BeLike '<133>1 * BSN_SESSION_OPEN *'
        $script:syslogCapture.Frames[1] | Should -BeLike '<134>1 * BSN_SESSION_OUTPUT *'
        $script:syslogCapture.Frames[2] | Should -BeLike '<134>1 * BSN_SESSION_INPUT *'
        Should -Invoke Send-BsnAuditSyslog -ModuleName Bsn.Host -Times 1 -Exactly
    }

    It 'threads the transport, port and facility through' {
        $script:syslogCapture = $null
        Mock Send-BsnAuditSyslog -ModuleName Bsn.Host -MockWith {
            param($Frames, $Server, $Port, $Transport)
            $script:syslogCapture = @{ Frames = @($Frames); Server = $Server; Port = $Port; Transport = $Transport }
        }

        Export-BsnAuditLog -Path $script:ExportCastPath -Target Syslog -Server 'log.lab' -Port 514 -Transport UDP -Facility Local3

        $script:syslogCapture.Transport | Should -Be 'UDP'
        $script:syslogCapture.Port | Should -Be 514
        $script:syslogCapture.Frames[0] | Should -BeLike '<157>1 *'
    }

    It 'does not send anything under -WhatIf' {
        Mock Send-BsnAuditSyslog -ModuleName Bsn.Host
        Export-BsnAuditLog -Path $script:ExportCastPath -Target Syslog -Server 'log.example' -WhatIf
        Should -Invoke Send-BsnAuditSyslog -ModuleName Bsn.Host -Times 0 -Exactly
    }
}

Describe 'Export-BsnAuditLog -Target SplunkHec' {
    It 'posts batched envelopes with the token from the environment' {
        $previousToken = $env:BSN_SPLUNK_HEC_TOKEN
        $env:BSN_SPLUNK_HEC_TOKEN = 'env-token'
        $script:hecCapture = $null
        Mock Send-BsnSplunkHec -ModuleName Bsn.Host -MockWith {
            param($Payloads, $Uri, $Token, $ChannelId, $Ack)
            $script:hecCapture = @{
                Payloads = @($Payloads)
                Uri = $Uri
                Token = $Token
                ChannelId = $ChannelId
                Ack = $Ack.IsPresent
            }
        }

        try {
            Export-BsnAuditLog -Path $script:ExportCastPath -Target SplunkHec -Uri 'https://splunk.example:8088' -Index 'audit' -BatchSize 2 -IncludeInput -IncludeOutput

            $script:hecCapture.Token | Should -Be 'env-token'
            $script:hecCapture.Uri | Should -Be 'https://splunk.example:8088'
            $script:hecCapture.ChannelId | Should -Not -BeNullOrEmpty
            $script:hecCapture.Payloads.Count | Should -Be 3
            $script:hecCapture.Ack | Should -BeFalse

            $firstBatch = @($script:hecCapture.Payloads[0] -split "`n")
            $firstBatch.Count | Should -Be 2
            $firstBatch[0] | Should -BeLike '*"sourcetype":"bsn:audit"*'
            ($firstBatch[0] | ConvertFrom-Json).fields.event_type | Should -Be 'session_open'
        }
        finally {
            if ($null -ne $previousToken) { $env:BSN_SPLUNK_HEC_TOKEN = $previousToken } else { Remove-Item Env:\BSN_SPLUNK_HEC_TOKEN -ErrorAction 'SilentlyContinue' }
        }
    }

    It 'prefers -Token over the environment and threads -Ack through' {
        $script:hecCapture = $null
        Mock Send-BsnSplunkHec -ModuleName Bsn.Host -MockWith {
            param($Payloads, $Uri, $Token, $ChannelId, $Ack)
            $script:hecCapture = @{
                Payloads = @($Payloads)
                Uri = $Uri
                Token = $Token
                ChannelId = $ChannelId
                Ack = $Ack.IsPresent
            }
        }

        Export-BsnAuditLog -Path $script:ExportCastPath -Target SplunkHec -Uri 'https://splunk.example:8088' -Token 'param-token' -Ack

        $script:hecCapture.Token | Should -Be 'param-token'
        $script:hecCapture.ChannelId | Should -Not -BeNullOrEmpty
        $script:hecCapture.Ack | Should -BeTrue
    }

    It 'fails without a token from either source' {
        $previousToken = $env:BSN_SPLUNK_HEC_TOKEN
        Remove-Item Env:\BSN_SPLUNK_HEC_TOKEN -ErrorAction 'SilentlyContinue'
        try {
            { Export-BsnAuditLog -Path $script:ExportCastPath -Target SplunkHec -Uri 'https://splunk.example:8088' } |
                Should -Throw '*No Splunk HEC token*'
        }
        finally {
            if ($null -ne $previousToken) { $env:BSN_SPLUNK_HEC_TOKEN = $previousToken }
        }
    }

    It 'refuses plain HTTP endpoints (token never travels unencrypted)' {
        { Export-BsnAuditLog -Path $script:ExportCastPath -Target SplunkHec -Uri 'http://splunk.example:8088' -Token 't' } |
            Should -Throw '*HTTPS*'
    }
}
