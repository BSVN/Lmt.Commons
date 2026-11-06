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
}
