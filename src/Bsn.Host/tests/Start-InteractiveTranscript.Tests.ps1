[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingComputerNameHardcoded', '', Justification = 'Not applicable - no computer names in this file.')]
param()

BeforeAll {
    $moduleRoot = Split-Path -Parent -Path $PSScriptRoot
    $manifestPath = Join-Path -Path $moduleRoot -ChildPath 'Bsn.Host.psd1'
    Import-Module -Name $manifestPath -Force -ErrorAction 'Stop'
}

Describe 'Start-InteractiveTranscript' {
    Context 'parameter set' {
        It 'supports WhatIf and Confirm' {
            $command = Get-Command -Name 'Start-InteractiveTranscript'
            $command.Parameters.ContainsKey('WhatIf') | Should -BeTrue
            $command.Parameters.ContainsKey('Confirm') | Should -BeTrue
        }

        It 'accepts the command as a positional parameter' {
            (Get-Command -Name 'Start-InteractiveTranscript').Parameters['Command'].ParameterType | Should -Be ([string])
        }
    }

    Context 'path handling' {
        BeforeEach {
            Mock -CommandName Test-BsnRecordingEnvironment -ModuleName 'Bsn.Host' { }
            Mock -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' {
                [pscustomobject]@{ ExitCode = 0; DurationSec = 1.5; StoppedByRequest = $false; Completed = $true }
            }
            Mock -CommandName Start-BsnUnixPtyRecording -ModuleName 'Bsn.Host' {
                [pscustomobject]@{ ExitCode = 0; DurationSec = 1.5; StoppedByRequest = $false; Completed = $true }
            }
            Mock -CommandName Get-BsnOperatingSystem -ModuleName 'Bsn.Host' { 'Windows' }
        }

        It 'rejects an existing cast file without -Force' {
            $existingPath = Join-Path -Path $TestDrive -ChildPath 'session.cast'
            Set-Content -LiteralPath $existingPath -Value 'existing'
            { Start-InteractiveTranscript -Path $existingPath -ErrorAction 'Stop' } | Should -Throw
        }

        It 'overwrites an existing cast file with -Force' {
            $existingPath = Join-Path -Path $TestDrive -ChildPath 'session.cast'
            Set-Content -LiteralPath $existingPath -Value 'existing'
            Start-InteractiveTranscript -Path $existingPath -Force
            Should -Invoke -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' -Times 1 -Exactly -Scope It
        }

        It 'rejects paths in a non-existing directory' {
            $missingDirectory = Join-Path -Path $TestDrive -ChildPath 'missing'
            { Start-InteractiveTranscript -Path (Join-Path -Path $missingDirectory -ChildPath 'x.cast') -ErrorAction 'Stop' } | Should -Throw
        }
    }

    Context 'dispatching to platform engines' {
        BeforeEach {
            Mock -CommandName Test-BsnRecordingEnvironment -ModuleName 'Bsn.Host' { }
        }

        It 'routes Windows to the ConPTY engine with a wrapped command line' {
            Mock -CommandName Get-BsnOperatingSystem -ModuleName 'Bsn.Host' { 'Windows' }
            Mock -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' {
                [pscustomobject]@{ ExitCode = 7; DurationSec = 2.25; StoppedByRequest = $false; Completed = $true }
            }
            Mock -CommandName Start-BsnUnixPtyRecording -ModuleName 'Bsn.Host' { }

            $recording = Start-InteractiveTranscript -Command 'echo hi' -Path (Join-Path -Path $TestDrive -ChildPath 'a.cast')

            Should -Invoke -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' -Times 1 -Exactly -Scope It -ParameterFilter { $CommandLine -like 'cmd.exe /d /c *echo hi*' }
            $recording.ExitCode | Should -Be 7
            $recording.DurationSec | Should -Be 2.25
        }

        It 'routes Linux to the script(1) engine' {
            Mock -CommandName Get-BsnOperatingSystem -ModuleName 'Bsn.Host' { 'Linux' }
            Mock -CommandName Start-BsnUnixPtyRecording -ModuleName 'Bsn.Host' {
                [pscustomobject]@{ ExitCode = 0; DurationSec = 1.0; StoppedByRequest = $false; Completed = $true }
            }
            Mock -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' { }

            Start-InteractiveTranscript -Command 'htop' -Path (Join-Path -Path $TestDrive -ChildPath 'b.cast')

            Should -Invoke -CommandName Start-BsnUnixPtyRecording -ModuleName 'Bsn.Host' -Times 1 -Exactly -Scope It -ParameterFilter { $Command -eq 'htop' }
        }

        It 'propagates the recorded exit code to LASTEXITCODE' {
            Mock -CommandName Get-BsnOperatingSystem -ModuleName 'Bsn.Host' { 'Windows' }
            Mock -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' {
                [pscustomobject]@{ ExitCode = 42; DurationSec = 1.0; StoppedByRequest = $false; Completed = $true }
            }

            Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'c.cast')
            $LASTEXITCODE | Should -Be 42
        }
    }

    Context 'recording options (RFC 421 semantics)' {
        BeforeEach {
            Mock -CommandName Test-BsnRecordingEnvironment -ModuleName 'Bsn.Host' { }
            Mock -CommandName Get-BsnOperatingSystem -ModuleName 'Bsn.Host' { 'Windows' }
            Mock -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' {
                [pscustomobject]@{ ExitCode = 0; DurationSec = 1.0; StoppedByRequest = $false; Completed = $true }
            }
            Mock -CommandName Start-BsnUnixPtyRecording -ModuleName 'Bsn.Host' { }
        }

        It 'does not render anything for the default Asciicast format' {
            Mock -CommandName Invoke-BsnCastRender -ModuleName 'Bsn.Host' { '/should/not/happen.gif' }

            $recording = Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'fmt.cast')

            Should -Invoke -CommandName Invoke-BsnCastRender -ModuleName 'Bsn.Host' -Times 0 -Exactly -Scope It
            $recording.VideoPath | Should -BeNullOrEmpty
        }

        It 'renders the requested video format after recording' {
            Mock -CommandName Invoke-BsnCastRender -ModuleName 'Bsn.Host' { '/recordings/demo.webm' }

            $recording = Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'fmt2.cast') -RecordingFormat 'WebM'

            Should -Invoke -CommandName Invoke-BsnCastRender -ModuleName 'Bsn.Host' -Times 1 -Exactly -Scope It -ParameterFilter { $Format -eq 'WebM' }
            $recording.VideoPath | Should -Be '/recordings/demo.webm'
        }

        It 'reports no video path when the renderer is unavailable' {
            Mock -CommandName Invoke-BsnCastRender -ModuleName 'Bsn.Host' { $null }

            $recording = Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'fmt3.cast') -RecordingFormat 'Gif'

            $recording.VideoPath | Should -BeNullOrEmpty
        }

        It 'applies the idle time limit after recording' {
            Mock -CommandName Optimize-BsnCastIdleTime -ModuleName 'Bsn.Host' { }

            Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'idle.cast') -RecordIdleTimeLimit 5

            Should -Invoke -CommandName Optimize-BsnCastIdleTime -ModuleName 'Bsn.Host' -Times 1 -Exactly -Scope It -ParameterFilter { $LimitSec -eq 5 }
        }

        It 'skips idle time processing for the default limit of zero' {
            Mock -CommandName Optimize-BsnCastIdleTime -ModuleName 'Bsn.Host' { }

            Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'idle2.cast')

            Should -Invoke -CommandName Optimize-BsnCastIdleTime -ModuleName 'Bsn.Host' -Times 0 -Exactly -Scope It
        }
    }

    Context 'rendering degradation (RFC 421 contract)' {
        It 'keeps the cast authoritative when the renderer is missing' {
            # 'agg' is not expected on CI images; when it genuinely is present this
            # test would fail - acceptable, since it proves the happy path instead.
            $aggCommand = Get-Command -Name 'agg' -ErrorAction 'SilentlyContinue'
            $castPath = Join-Path -Path $TestDrive -ChildPath 'degrade.cast'
            Set-Content -LiteralPath $castPath -Value '{"version": 2, "width": 80, "height": 24, "timestamp": 1793895000}'

            if ($aggCommand) {
                Set-ItResult -Skipped -Because 'agg is present on PATH, so the degradation path cannot be exercised.'
            }

            $renderResult = & (Get-Module -Name 'Bsn.Host') { param($p) Invoke-BsnCastRender -CastPath $p -Format 'Gif' } $castPath

            $renderResult | Should -BeNullOrEmpty
            (Test-Path -LiteralPath ([System.IO.Path]::ChangeExtension($castPath, 'gif'))) | Should -BeFalse
            (Get-Item -LiteralPath $castPath).Length | Should -BeGreaterThan 0
        }
    }

    Context 'environment constraint checks' {
        It 'runs the pre-flight checks before dispatching' {
            Mock -CommandName Test-BsnRecordingEnvironment -ModuleName 'Bsn.Host' { }
            Mock -CommandName Get-BsnOperatingSystem -ModuleName 'Bsn.Host' { 'Windows' }
            Mock -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' {
                [pscustomobject]@{ ExitCode = 0; DurationSec = 1.0; StoppedByRequest = $false; Completed = $true }
            }

            Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'env.cast')

            Should -Invoke -CommandName Test-BsnRecordingEnvironment -ModuleName 'Bsn.Host' -Times 1 -Exactly -Scope It
        }

        It 'rejects unknown platforms with an explicit message' {
            Mock -CommandName Get-BsnOperatingSystem -ModuleName 'Bsn.Host' { 'Unknown' }

            { Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'unknown.cast') -ErrorAction 'Stop' } | Should -Throw '*not supported on this platform*'
        }
    }

    Context 'stop signaling' {
        BeforeEach {
            Mock -CommandName Test-BsnRecordingEnvironment -ModuleName 'Bsn.Host' { }
            Mock -CommandName Get-BsnOperatingSystem -ModuleName 'Bsn.Host' { 'Windows' }
            Mock -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' {
                [pscustomobject]@{ ExitCode = 0; DurationSec = 1.0; StoppedByRequest = $true; Completed = $true }
            }
        }

        It 'passes a stop file to the engine and restores the environment afterwards' {
            $previousValue = $env:BsnHostRecordingStopFile

            Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'stop.cast')

            Should -Invoke -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' -Times 1 -Exactly -Scope It -ParameterFilter { $StopFilePath -and ($StopFilePath -like '*BsnHostRecordingStop_*.stop') }
            $env:BsnHostRecordingStopFile | Should -Be $previousValue
        }

        It 'reports when the recording was stopped by request' {
            $recording = Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'stop2.cast')
            $recording.StoppedByRequest | Should -BeTrue
        }
    }

    Context 'support for -WhatIf' {
        It 'records nothing under -WhatIf' {
            Mock -CommandName Test-BsnRecordingEnvironment -ModuleName 'Bsn.Host' { }
            Mock -CommandName Get-BsnOperatingSystem -ModuleName 'Bsn.Host' { 'Windows' }
            Mock -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' { }
            Mock -CommandName Start-BsnUnixPtyRecording -ModuleName 'Bsn.Host' { }

            Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'd.cast') -WhatIf

            Should -Invoke -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' -Times 0 -Exactly -Scope It
            Should -Invoke -CommandName Start-BsnUnixPtyRecording -ModuleName 'Bsn.Host' -Times 0 -Exactly -Scope It
        }
    }

    Context 'default shell resolution' {
        It 'returns an existing shell path' {
            $shellPath = & (Get-Module -Name 'Bsn.Host') { Get-BsnDefaultShell }
            $shellPath | Should -Not -BeNullOrEmpty
            (Get-Command -Name $shellPath -ErrorAction 'SilentlyContinue') | Should -Not -BeNullOrEmpty
        }
    }
}
