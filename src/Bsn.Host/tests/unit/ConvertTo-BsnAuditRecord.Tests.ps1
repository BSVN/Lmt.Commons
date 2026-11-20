[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingComputerNameHardcoded', '', Justification = 'Test fixtures use synthetic computer names.')]
param()

BeforeAll {
    $moduleRoot = Split-Path -Parent -Path (Split-Path -Parent -Path $PSScriptRoot)
    # Make the repo sibling module Bsn.Common resolvable for RequiredModules validation.
    $env:PSModulePath = '{0}{1}{2}' -f (Split-Path -Parent -Path $moduleRoot), [System.IO.Path]::PathSeparator, $env:PSModulePath
    $manifestPath = Join-Path -Path $moduleRoot -ChildPath 'Bsn.Host.psd1'
    # The module's DLL may already be loaded in this process (e.g., by PSScriptAnalyzer
    # analyzing the manifest), which makes Import-Module fail with FileLoadException.
    # Fall back to importing the psm1 directly - the assembly is already in memory.
    try {
        Import-Module -Name $manifestPath -Force -ErrorAction 'Stop'
    }
    catch [System.IO.FileLoadException] {
        Import-Module -Name (Join-Path $moduleRoot 'Bsn.Host.psm1') -Force -ErrorAction 'Stop'
    }

    $script:EpochStart = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    $script:Rfc3339Format = "yyyy-MM-dd'T'HH:mm:ss.ffffff'Z'"
    $script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $script:EscapeCharacter = [string][char]27

    function Get-BsnAuditExpectedTime {
        param([double]$Seconds)
        return $script:EpochStart.AddSeconds($Seconds).ToString($script:Rfc3339Format, $script:Invariant)
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

    # Cast fixtures: event lines are built as strings at the call site
    # (payloads are JSON-encoded inline) so no nested arrays are involved.
    # A v2 session exercising every taxonomy source except the v3 exit
    # event: echoed command, recorded input, colored overtyped output,
    # resize, marker.
    $script:FirstOutput = 'PS C:\> Get-ChildItem' + "`r`n"
    $script:Input = 'dir' + "`r"
    $script:SecondOutput = $script:EscapeCharacter + '[1;32mprogress 10%' + $script:EscapeCharacter + '[0m' + [string][char]13 + 'progress 50%' + "`r`n"

    $script:AuditCastPath = Join-Path -Path $TestDrive -ChildPath 'audit.cast'
    @(
        '{"version": 2, "width": 100, "height": 40, "timestamp": 1793895000, "env": {"SHELL": "pwsh", "TERM": "xterm-256color"}}'
        ('[0.1, "o", {0}]' -f ($script:FirstOutput | ConvertTo-Json -Compress))
        ('[0.5, "i", {0}]' -f ($script:Input | ConvertTo-Json -Compress))
        ('[0.7, "o", {0}]' -f ($script:SecondOutput | ConvertTo-Json -Compress))
        '[0.9, "r", "80x24"]'
        ('[1.1, "m", {0}]' -f ('checkpoint' | ConvertTo-Json -Compress))
    ) | Set-Content -LiteralPath $script:AuditCastPath

    $script:V3CastPath = Join-Path -Path $TestDrive -ChildPath 'audit-v3.cast'
    @(
        '{"version": 3, "term": {"cols": 120, "rows": 30, "type": "xterm-256color"}, "timestamp": 1793895000, "command": "pwsh -NoProfile"}'
        ('[0.1, "o", {0}]' -f ("alpha`r`n" | ConvertTo-Json -Compress))
        '[0.2, "x", "7"]'
    ) | Set-Content -LiteralPath $script:V3CastPath

    # A cast with a typed secret, for masking tests.
    $script:SecretCastPath = Join-Path -Path $TestDrive -ChildPath 'secret.cast'
    @(
        '{"version": 2, "width": 80, "height": 24, "timestamp": 1793895000}'
        ('[0.2, "i", {0}]' -f (('password=hunter2' + "`r") | ConvertTo-Json -Compress))
    ) | Set-Content -LiteralPath $script:SecretCastPath

    # A cast with a long output line, for the truncation test.
    $script:LongOutputCastPath = Join-Path -Path $TestDrive -ChildPath 'long-output.cast'
    $script:LongOutput = ('x' * 100) + "`r`n"
    @(
        '{"version": 2, "width": 80, "height": 24, "timestamp": 1793895000}'
        ('[0.1, "o", {0}]' -f ($script:LongOutput | ConvertTo-Json -Compress))
    ) | Set-Content -LiteralPath $script:LongOutputCastPath
}

Describe 'ConvertTo-BsnAuditRecord' {
    Context 'taxonomy (default)' {
        BeforeAll {
            $script:Records = @(ConvertTo-BsnAuditRecord -Path $script:AuditCastPath)
            $script:Types = @($script:Records | ForEach-Object -Process { $_.event.type })
        }

        It 'emits open, resize, marker, close and summary without input/output by default' {
            $script:Types | Should -Be @('session_open', 'session_resize', 'session_marker', 'session_close', 'session_summary')
        }

        It 'stamps session_open with schema, severity and RFC 3339 UTC time' {
            $open = $script:Records[0]
            $open.schema | Should -Be 'bsn.audit/1'
            $open.severity | Should -Be 'notice'
            $open.event.kind | Should -Be 'session_activity'
            $open.event.outcome | Should -Be 'success'
            $open.time | Should -Be (Get-BsnAuditExpectedTime -Seconds 1793895000)
            $open.position | Should -BeOfType [pscustomobject]
            $open.position.offset_ms | Should -Be 0
            $open.position.event_index | Should -Be 0
            $open.position.stream | Should -Be 'meta'
        }

        It 'carries the session context (derived id, blank host/user, header shell)' {
            $open = $script:Records[0]
            $open.session.id | Should -BeLike 'bsn-*'
            $open.session.recorded_by | Should -BeLike 'bsn.host *'
            $open.session.host | Should -Be ''
            $open.session.user | Should -Be ''
            $open.session.shell | Should -Be 'pwsh'
            $open.session.origin | Should -Be 'local'
        }

        It 'carries the v2 terminal size on session_open' {
            $script:Records[0].terminal.columns | Should -Be 100
            $script:Records[0].terminal.rows | Should -Be 40
        }

        It 'fills ComputerName and UserName when supplied' {
            $record = ConvertTo-BsnAuditRecord -Path $script:AuditCastPath -ComputerName 'ws01' -UserName 'CONTOSO\jdoe' -Origin ssh |
                Select-Object -First 1
            $record.session.host | Should -Be 'ws01'
            $record.session.user | Should -Be 'CONTOSO\jdoe'
            $record.session.origin | Should -Be 'ssh'
        }

        It 'derives the session id from the cast hash unless overridden' {
            $castHash = Get-BsnTestFileHash -File $script:AuditCastPath
            $script:Records[0].session.id | Should -Be ('bsn-' + $castHash.Substring(0, 12))
            $override = ConvertTo-BsnAuditRecord -Path $script:AuditCastPath -SessionId 'audit-42' | Select-Object -First 1
            $override.session.id | Should -Be 'audit-42'
        }

        It 'binds every record to the cast evidence' {
            $castHash = Get-BsnTestFileHash -File $script:AuditCastPath
            foreach ($record in $script:Records) {
                $record.evidence.cast_path | Should -Be (Resolve-Path -LiteralPath $script:AuditCastPath).ProviderPath
                $record.evidence.cast_sha256 | Should -Be $castHash
                $record.evidence.transcript_sha256 | Should -BeNullOrEmpty
            }
        }

        It 'embeds transcript_sha256 when -TranscriptPath points at the rendering' {
            $transcriptPath = Join-Path -Path $TestDrive -ChildPath 'rendered.txt'
            Set-Content -LiteralPath $transcriptPath -Value 'rendering' -NoNewline
            $record = ConvertTo-BsnAuditRecord -Path $script:AuditCastPath -TranscriptPath $transcriptPath | Select-Object -First 1
            $record.evidence.transcript_sha256 | Should -Be (Get-BsnTestFileHash -File $transcriptPath)
        }

        It 'rejects a missing transcript file' {
            { ConvertTo-BsnAuditRecord -Path $script:AuditCastPath -TranscriptPath (Join-Path -Path $TestDrive -ChildPath 'missing.txt') } |
                Should -Throw '*does not exist*'
        }
    }

    Context 'timeline events' {
        It 'emits session_resize with the payload size at debug level' {
            $resize = ConvertTo-BsnAuditRecord -Path $script:AuditCastPath | Where-Object { $_.event.type -eq 'session_resize' }
            $resize.severity | Should -Be 'debug'
            $resize.position.stream | Should -Be 'control'
            $resize.position.offset_ms | Should -Be 900
            $resize.resize.columns | Should -Be 80
            $resize.resize.rows | Should -Be 24
        }

        It 'emits session_marker with the payload label at notice level' {
            $marker = ConvertTo-BsnAuditRecord -Path $script:AuditCastPath | Where-Object { $_.event.type -eq 'session_marker' }
            $marker.severity | Should -Be 'notice'
            $marker.position.stream | Should -Be 'marker'
            $marker.marker.label | Should -Be 'checkpoint'
            $marker.time | Should -Be (Get-BsnAuditExpectedTime -Seconds (1793895000 + 1.1))
        }

        It 'computes session_close duration, raw byte counts and exit code' {
            $close = ConvertTo-BsnAuditRecord -Path $script:AuditCastPath | Where-Object { $_.event.type -eq 'session_close' }
            $close.close.duration_ms | Should -Be 1100
            $close.close.input_bytes | Should -Be ([System.Text.Encoding]::UTF8.GetByteCount($script:Input))
            $expectedOutputBytes = ([System.Text.Encoding]::UTF8.GetByteCount($script:FirstOutput) +
                [System.Text.Encoding]::UTF8.GetByteCount($script:SecondOutput))
            $close.close.output_bytes | Should -Be $expectedOutputBytes
            $close.close.exit_code | Should -BeNullOrEmpty
            $close.position.event_index | Should -Be 5
        }

        It 'mirrors counts and exit code into session_summary (always emitted)' {
            $summary = ConvertTo-BsnAuditRecord -Path $script:AuditCastPath | Where-Object { $_.event.type -eq 'session_summary' }
            $summary.summary.duration_ms | Should -Be 1100
            $summary.summary.events.input | Should -Be 0
            $summary.summary.events.output | Should -Be 0
            $summary.summary.events.resize | Should -Be 1
            $summary.summary.events.marker | Should -Be 1
        }

        It 'reads the v3 terminal size, command and exit-status event' {
            $records = @(ConvertTo-BsnAuditRecord -Path $script:V3CastPath)
            $records[0].terminal.columns | Should -Be 120
            $records[0].terminal.rows | Should -Be 30
            $records[0].session.command | Should -Be 'pwsh -NoProfile'
            $close = $records | Where-Object { $_.event.type -eq 'session_close' }
            $close.close.exit_code | Should -Be 7
        }

        It 'tolerates a cast header without a timestamp (epoch start)' {
            $path = Join-Path -Path $TestDrive -ChildPath 'no-timestamp.cast'
            Set-Content -LiteralPath $path -Value '{"version": 2, "width": 80, "height": 24}' -NoNewline
            $open = ConvertTo-BsnAuditRecord -Path $path | Select-Object -First 1
            $open.time | Should -Be (Get-BsnAuditExpectedTime -Seconds 0)
        }
    }

    Context 'input records (opt-in, masked)' {
        It 'suppresses input records by default and includes them with -IncludeInput' {
            (ConvertTo-BsnAuditRecord -Path $script:AuditCastPath | Where-Object { $_.event.type -eq 'session_input' }) | Should -BeNullOrEmpty
            $inputRecord = ConvertTo-BsnAuditRecord -Path $script:AuditCastPath -IncludeInput |
                Where-Object { $_.event.type -eq 'session_input' }
            $inputRecord.severity | Should -Be 'info'
            $inputRecord.position.stream | Should -Be 'input'
            $inputRecord.position.offset_ms | Should -Be 500
            $inputRecord.input.text | Should -Be $script:Input
            $inputRecord.input.masked | Should -BeTrue
        }

        It 'masks key-like secret values in input records' {
            $secretRecord = ConvertTo-BsnAuditRecord -Path $script:SecretCastPath -IncludeInput |
                Where-Object { $_.event.type -eq 'session_input' }
            $secretRecord.input.text | Should -BeLike 'password=***'
            $secretRecord.input.text.Contains('hunter2') | Should -BeFalse
            $secretRecord.input.masked | Should -BeTrue
        }

        It 'keeps raw text with -NoMaskSecrets (masked false)' {
            $rawRecord = ConvertTo-BsnAuditRecord -Path $script:SecretCastPath -IncludeInput -NoMaskSecrets |
                Where-Object { $_.event.type -eq 'session_input' }
            $rawRecord.input.text.Contains('hunter2') | Should -BeTrue
            $rawRecord.input.masked | Should -BeFalse
        }

        It 'counts raw input bytes in session_close even when records are suppressed' {
            $close = ConvertTo-BsnAuditRecord -Path $script:AuditCastPath | Where-Object { $_.event.type -eq 'session_close' }
            $close.close.input_bytes | Should -Be ([System.Text.Encoding]::UTF8.GetByteCount($script:Input))
        }
    }

    Context 'output records (opt-in, ANSI-stripped, capped)' {
        It 'suppresses output records by default and includes stripped text with -IncludeOutput' {
            (ConvertTo-BsnAuditRecord -Path $script:AuditCastPath | Where-Object { $_.event.type -eq 'session_output' }) | Should -BeNullOrEmpty
            $outputs = @(ConvertTo-BsnAuditRecord -Path $script:AuditCastPath -IncludeOutput |
                Where-Object { $_.event.type -eq 'session_output' })
            $outputs.Count | Should -Be 2
            $outputs[0].output.text | Should -Be ('PS C:\> Get-ChildItem' + "`n")
            $outputs[0].output.truncated | Should -BeFalse
        }

        It 'resolves carriage-return overtype and strips escape sequences' {
            $overtype = ConvertTo-BsnAuditRecord -Path $script:AuditCastPath -IncludeOutput |
                Where-Object { $_.event.type -eq 'session_output' } |
                Select-Object -Index 1
            $overtype.output.text | Should -Be ('progress 50%' + "`n")
            $overtype.output.text.Contains([string][char]27) | Should -BeFalse
        }

        It 'caps output text at -OutputSizeCap and flags truncation' {
            $capped = ConvertTo-BsnAuditRecord -Path $script:LongOutputCastPath -IncludeOutput -OutputSizeCap 10 |
                Where-Object { $_.event.type -eq 'session_output' } |
                Select-Object -First 1
            $capped.output.text | Should -Be 'xxxxxxxxxx'
            $capped.output.truncated | Should -BeTrue
        }
    }
}
