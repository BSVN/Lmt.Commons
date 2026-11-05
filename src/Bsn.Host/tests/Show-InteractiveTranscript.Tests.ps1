BeforeAll {
    $moduleRoot = Split-Path -Parent -Path $PSScriptRoot
    $manifestPath = Join-Path -Path $moduleRoot -ChildPath 'Bsn.Host.psd1'
    Import-Module -Name $manifestPath -Force -ErrorAction 'Stop'
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
