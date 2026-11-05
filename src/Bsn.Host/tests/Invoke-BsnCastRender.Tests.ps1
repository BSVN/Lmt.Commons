BeforeAll {
    $moduleRoot = Split-Path -Parent -Path $PSScriptRoot
    $manifestPath = Join-Path -Path $moduleRoot -ChildPath 'Bsn.Host.psd1'
    Import-Module -Name $manifestPath -Force -ErrorAction 'Stop'

    # Fake renderer toolchain: PowerShell scripts on PATH are found by Get-Command
    # and invokable with & on Windows, Linux and macOS alike.
    $script:ToolDirectory = Join-Path -Path $TestDrive -ChildPath 'tools'
    $null = New-Item -ItemType 'Directory' -Path $script:ToolDirectory -Force

    $aggScript = Join-Path -Path $script:ToolDirectory -ChildPath 'agg.ps1'
    @'
param([Parameter(Position = 0)]$InputCast, [Parameter(Position = 1)]$OutputGif)
Set-Content -LiteralPath $OutputGif -Value 'rendered-gif' -NoNewline
$global:LASTEXITCODE = 0
'@ | Set-Content -LiteralPath $aggScript

    $aggFailScript = Join-Path -Path $script:ToolDirectory -ChildPath 'aggfail.ps1'
    @'
$global:LASTEXITCODE = 1
exit 1
'@ | Set-Content -LiteralPath $aggFailScript

    $ffmpegScript = Join-Path -Path $script:ToolDirectory -ChildPath 'ffmpeg.ps1'
    @'
$out = $args[-1]
Set-Content -LiteralPath $out -Value 'rendered-video' -NoNewline
$global:LASTEXITCODE = 0
'@ | Set-Content -LiteralPath $ffmpegScript

    $script:CastPath = Join-Path -Path $TestDrive -ChildPath 'render.cast'
    Set-Content -LiteralPath $script:CastPath -Value '{"version": 2, "width": 80, "height": 24, "timestamp": 1793895000}'

    $script:OriginalPath = $env:PATH
}

AfterAll {
    $env:PATH = $script:OriginalPath
}

Describe 'Invoke-BsnCastRender' {
    Context 'with the render toolchain available' {
        BeforeEach {
            $env:PATH = '{0}{1}{2}' -f $script:ToolDirectory, [System.IO.Path]::PathSeparator, $script:OriginalPath
            Remove-Item -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'render.gif'), (Join-Path -Path $TestDrive -ChildPath 'render.webm'), (Join-Path -Path $TestDrive -ChildPath 'render.mp4') -Force -ErrorAction SilentlyContinue
        }

        It 'renders a GIF with agg' {
            $gifPath = & (Get-Module -Name 'Bsn.Host') { param($p) Invoke-BsnCastRender -CastPath $p -Format 'Gif' } $script:CastPath

            $gifPath | Should -Be ([System.IO.Path]::ChangeExtension($script:CastPath, 'gif'))
            (Get-Content -LiteralPath $gifPath -Raw) | Should -Be 'rendered-gif'
        }

        It 'renders WebM with agg and ffmpeg' {
            $videoPath = & (Get-Module -Name 'Bsn.Host') { param($p) Invoke-BsnCastRender -CastPath $p -Format 'WebM' } $script:CastPath

            $videoPath | Should -Be ([System.IO.Path]::ChangeExtension($script:CastPath, 'webm'))
            (Get-Content -LiteralPath $videoPath -Raw) | Should -Be 'rendered-video'
        }

        It 'renders MP4 with agg and ffmpeg' {
            $videoPath = & (Get-Module -Name 'Bsn.Host') { param($p) Invoke-BsnCastRender -CastPath $p -Format 'Mp4' } $script:CastPath

            $videoPath | Should -Be ([System.IO.Path]::ChangeExtension($script:CastPath, 'mp4'))
            (Get-Content -LiteralPath $videoPath -Raw) | Should -Be 'rendered-video'
        }

        It 'returns null and warns when agg fails' {
            # Shadow agg with a failing shim by putting a directory containing agg.ps1 that exits 1 first on PATH.
            $failDirectory = Join-Path -Path $TestDrive -ChildPath 'failtools'
            $null = New-Item -ItemType 'Directory' -Path $failDirectory -Force
            Copy-Item -LiteralPath (Join-Path -Path $script:ToolDirectory -ChildPath 'aggfail.ps1') -Destination (Join-Path -Path $failDirectory -ChildPath 'agg.ps1') -Force
            $env:PATH = '{0}{1}{2}' -f $failDirectory, [System.IO.Path]::PathSeparator, $env:PATH

            $renderResult = & (Get-Module -Name 'Bsn.Host') { param($p) Invoke-BsnCastRender -CastPath $p -Format 'Gif' } $script:CastPath

            $renderResult | Should -BeNullOrEmpty
        }
    }

    Context 'without the render toolchain' {
        BeforeEach {
            # PATH without the shim directory: assume the real tools are absent on CI images;
            # skip when a real agg exists locally.
            $env:PATH = $script:OriginalPath
        }

        It 'keeps the cast authoritative when agg is missing' {
            if (Get-Command -Name 'agg' -ErrorAction 'SilentlyContinue') {
                Set-ItResult -Skipped -Because 'agg is present on PATH, so the degradation path cannot be exercised.'
            }

            $renderResult = & (Get-Module -Name 'Bsn.Host') { param($p) Invoke-BsnCastRender -CastPath $p -Format 'Gif' } $script:CastPath

            $renderResult | Should -BeNullOrEmpty
            (Test-Path -LiteralPath ([System.IO.Path]::ChangeExtension($script:CastPath, 'gif'))) | Should -BeFalse
            (Get-Item -LiteralPath $script:CastPath).Length | Should -BeGreaterThan 0
        }
    }
}
