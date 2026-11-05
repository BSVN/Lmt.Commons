BeforeAll {
    $moduleRoot = Split-Path -Parent -Path $PSScriptRoot
    $manifestPath = Join-Path -Path $moduleRoot -ChildPath 'Bsn.Host.psd1'
    Import-Module -Name $manifestPath -Force -ErrorAction 'Stop'
}

Describe 'Optimize-BsnCastIdleTime' {
    BeforeEach {
        $castPath = Join-Path -Path $TestDrive -ChildPath 'idle.cast'
        @'
{"version": 2, "width": 80, "height": 24, "timestamp": 1793895000, "title": "Bsn.Host interactive transcript", "env": {"SHELL": "pwsh", "TERM": "xterm-256color"}}
[0, "o", "first"]
[5, "o", "second"]
[20, "o", "third"]
[20.5, "i", "x"]
'@ | Set-Content -LiteralPath $castPath -NoNewline
    }

    It 'compresses idle gaps longer than the limit to the limit' {
        & (Get-Module -Name 'Bsn.Host') { param($p, $l) Optimize-BsnCastIdleTime -Path $p -LimitSec $l } $castPath 3

        $events = @(Get-Content -LiteralPath $castPath | Select-Object -Skip 1 | ForEach-Object -Process { , ($_ | ConvertFrom-Json) })
        $events[0][0] | Should -Be 0
        $events[1][0] | Should -Be 3
        $events[2][0] | Should -Be 6
        $events[3][0] | Should -Be 9
    }

    It 'preserves event payloads untouched' {
        $original = Get-Content -LiteralPath $castPath
        & (Get-Module -Name 'Bsn.Host') { param($p, $l) Optimize-BsnCastIdleTime -Path $p -LimitSec $l } $castPath 3
        $adjusted = Get-Content -LiteralPath $castPath

        $adjusted[0] | Should -Be $original[0]
        ($adjusted[1] -replace '^\[[\d.]+', '') | Should -Be ($original[1] -replace '^\[[\d.]+', '')
        ($adjusted[3] -replace '^\[[\d.]+', '') | Should -Be ($original[3] -replace '^\[[\d.]+', '')
    }

    It 'keeps short gaps and the header unchanged' {
        & (Get-Module -Name 'Bsn.Host') { param($p, $l) Optimize-BsnCastIdleTime -Path $p -LimitSec $l } $castPath 900
        $events = @(Get-Content -LiteralPath $castPath | Select-Object -Skip 1 | ForEach-Object -Process { , ($_ | ConvertFrom-Json) })
        $events[1][0] | Should -Be 5
        $events[2][0] | Should -Be 20
    }

    It 'clamps v3 interval events directly' {
        $v3Path = Join-Path -Path $TestDrive -ChildPath 'v3idle.cast'
        @'
{"version": 3, "term": {"cols": 80, "rows": 24}}
[0.5, "o", "a"]
[30, "o", "b"]
[0.25, "o", "c"]
'@ | Set-Content -LiteralPath $v3Path -NoNewline

        & (Get-Module -Name 'Bsn.Host') { param($p, $l) Optimize-BsnCastIdleTime -Path $p -LimitSec $l } $v3Path 3

        $events = @(Get-Content -LiteralPath $v3Path | Select-Object -Skip 1 | ForEach-Object -Process { , ($_ | ConvertFrom-Json) })
        $events[0][0] | Should -Be 0.5
        $events[1][0] | Should -Be 3
        $events[2][0] | Should -Be 0.25
    }
}
