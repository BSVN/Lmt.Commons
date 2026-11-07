BeforeAll {
    $moduleRoot = Split-Path -Parent -Path (Split-Path -Parent -Path $PSScriptRoot)
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
}

Describe 'Get-BsnCastTimeline' {
    BeforeAll {
        $script:CastPath = Join-Path -Path $TestDrive -ChildPath 'timeline.cast'
        @'
{"version": 2, "width": 80, "height": 24, "timestamp": 1793895000, "title": "Bsn.Host interactive transcript", "env": {"SHELL": "pwsh", "TERM": "xterm-256color"}}
[0, "o", "first"]
[0.5, "o", "second"]
[1, "r", "100x40"]
[1.5, "i", "x"]
'@ | Set-Content -LiteralPath $script:CastPath -NoNewline
    }

    It 'parses the header and all events' {
        $timeline = & (Get-Module -Name 'Bsn.Host') { param($p) Get-BsnCastTimeline -Path $p } $script:CastPath

        $timeline.Header.version | Should -Be 2
        $timeline.Header.width | Should -Be 80
        $timeline.Events.Count | Should -Be 4
        $timeline.Events[0][2] | Should -Be 'first'
        $timeline.Events[2][1] | Should -Be 'r'
    }

    It 'rejects files that are not asciicast v2' {
        $invalidPath = Join-Path -Path $TestDrive -ChildPath 'invalid.cast'
        Set-Content -LiteralPath $invalidPath -Value '{"version": 1}'

        { & (Get-Module -Name 'Bsn.Host') { param($p) Get-BsnCastTimeline -Path $p } $invalidPath } | Should -Throw '*not an asciicast v2*'
    }

    It 'normalizes v3 interval events to absolute times and skips comments' {
        $v3Path = Join-Path -Path $TestDrive -ChildPath 'v3.cast'
        @'
{"version": 3, "term": {"cols": 80, "rows": 24, "type": "xterm-256color"}, "timestamp": 1793895000}
# a comment line, legal in v3
[0.1, "o", "first"]
[0.25, "o", "second"]
[0.5, "r", "100x40"]
[0, "x", "0"]
'@ | Set-Content -LiteralPath $v3Path -NoNewline

        $timeline = & (Get-Module -Name 'Bsn.Host') { param($p) Get-BsnCastTimeline -Path $p } $v3Path

        $timeline.Header.version | Should -Be 3
        $timeline.Events.Count | Should -Be 4
        $timeline.Events[0][0] | Should -Be 0.1
        $timeline.Events[1][0] | Should -Be 0.35
        $timeline.Events[2][0] | Should -Be 0.85
        $timeline.Events[2][1] | Should -Be 'r'
        $timeline.Events[3][1] | Should -Be 'x'
    }

    It 'rejects missing files' {
        { & (Get-Module -Name 'Bsn.Host') { param($p) Get-BsnCastTimeline -Path $p } (Join-Path -Path $TestDrive -ChildPath 'missing.cast') } | Should -Throw '*does not exist*'
    }
}

Describe 'Show-InteractiveTranscript' {
    BeforeAll {
        $script:ShowPath = Join-Path -Path $TestDrive -ChildPath 'show.cast'
        @'
{"version": 2, "width": 80, "height": 24, "timestamp": 1793895000, "env": {"TERM": "xterm-256color"}}
[0, "o", "hello "]
[0.01, "o", "world"]
'@ | Set-Content -LiteralPath $script:ShowPath -NoNewline
    }

    It 'plays back a recording without error' {
        { Show-InteractiveTranscript -Path $script:ShowPath -Speed 100 } | Should -Not -Throw
    }

    It 'accepts the cast path from the pipeline' {
        { $script:ShowPath | Show-InteractiveTranscript -Speed 100 } | Should -Not -Throw
    }

    It 'restores the console output encoding after playback' {
        # https://github.com/BSVN/Lmt.Commons/issues/5
        # The playback temporarily switches the console output encoding to
        # UTF-8 (Windows PowerShell 5.1 hosts write [Console] output through
        # the codepage, which mangles non-CP437 box characters to '?'); the
        # original encoding must come back afterwards.
        if ('System.Text.CodePagesEncodingProvider' -as [type]) {
            [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
        }
        $previousEncoding = [Console]::OutputEncoding
        try {
            [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(437)

            Show-InteractiveTranscript -Path $script:ShowPath -Speed 100

            [Console]::OutputEncoding.CodePage | Should -Be 437 -Because 'the playback must restore the console output encoding it found'
        }
        finally {
            [Console]::OutputEncoding = $previousEncoding
        }
    }

    It 'writes heavy box characters losslessly even when the console encodes them as question marks' {
        # https://github.com/BSVN/Lmt.Commons/issues/5
        # Reproduces the reported OpenCode viewer bug: a cast with heavy
        # box-drawing characters (U+2503 border, U+2579 corner - NOT in
        # CP437) played back by a host whose [Console]::Write goes through
        # the console output codepage. Before the fix those characters
        # reached the screen as literal '?'; the playback must switch the
        # console output encoding to UTF-8 so they arrive intact. A child
        # pwsh with redirected stdout encodes [Console]::Write through
        # [Console]::OutputEncoding - the same lossy path as an interactive
        # Windows PowerShell 5.1 host.
        if ('System.Text.CodePagesEncodingProvider' -as [type]) {
            [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
        }

        $unicodeCastPath = Join-Path -Path $TestDrive -ChildPath 'show-unicode.cast'
        $eventText = 'A' + [string][char]0x2503 + 'B' + [string][char]0x2579 + 'C'
        $eventJson = ConvertTo-Json -InputObject $eventText -Compress
        $castLines = @(
            '{"version": 2, "width": 80, "height": 24, "timestamp": 1793895000, "env": {"TERM": "xterm-256color"}}'
            ('[0, "o", ' + $eventJson + ']')
        )
        Set-Content -LiteralPath $unicodeCastPath -Value $castLines -Encoding UTF8

        $childScriptPath = Join-Path -Path $TestDrive -ChildPath 'show-oem-child.ps1'
        @'
param($ModuleRoot, $CastPath)
$env:PSModulePath = (Split-Path -Parent -Path $ModuleRoot) + [System.IO.Path]::PathSeparator + $env:PSModulePath
Import-Module (Join-Path $ModuleRoot 'Bsn.Host.psd1') -Force
[System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
[Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(437)
Show-InteractiveTranscript -Path $CastPath
'@ | Set-Content -LiteralPath $childScriptPath -Encoding UTF8

        $childOutputPath = Join-Path -Path $TestDrive -ChildPath 'show-oem-out.txt'
        $childErrorPath = Join-Path -Path $TestDrive -ChildPath 'show-oem-err.txt'
        # -WindowStyle is Windows-only (Unix pwsh rejects the parameter); on
        # Unix the child simply inherits the harness's redirected stdio, which
        # is exactly what the lossy-encoding scenario needs.
        $childStartArguments = @{
            FilePath = (Get-Process -Id $PID).Path
            ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $childScriptPath, '-ModuleRoot', $moduleRoot, '-CastPath', $unicodeCastPath)
            RedirectStandardOutput = $childOutputPath
            RedirectStandardError = $childErrorPath
            PassThru = $true
            Wait = $true
        }
        if ($IsWindows) { $childStartArguments.WindowStyle = 'Hidden' }
        $null = Start-Process @childStartArguments

        # The playback switched the console output encoding to UTF-8 for the
        # write: the heavy box characters arrive as UTF-8, not as '?'.
        $playbackBytes = [System.IO.File]::ReadAllBytes($childOutputPath)
        $playbackText = [System.Text.Encoding]::UTF8.GetString($playbackBytes)
        $playbackText.Contains([string][char]0x2503) | Should -BeTrue -Because 'the heavy vertical border must survive playback on a CP437-encoding console (issue #5 viewer bug)'
        $playbackText.Contains([string][char]0x2579) | Should -BeTrue -Because 'the heavy corner must survive playback on a CP437-encoding console (issue #5 viewer bug)'
        $playbackText | Should -Not -Match '\?' -Because ('characters outside CP437 must not degrade to literal question marks (got: {0})' -f $playbackText)
    }
}
