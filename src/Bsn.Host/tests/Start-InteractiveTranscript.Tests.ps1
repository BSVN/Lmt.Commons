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
            Mock -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' {
                [pscustomobject]@{ ExitCode = 0; DurationSec = 1.5; Completed = $true }
            }
            Mock -CommandName Start-BsnUnixPtyRecording -ModuleName 'Bsn.Host' {
                [pscustomobject]@{ ExitCode = 0; DurationSec = 1.5; Completed = $true }
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
        It 'routes Windows to the ConPTY engine with a wrapped command line' {
            Mock -CommandName Get-BsnOperatingSystem -ModuleName 'Bsn.Host' { 'Windows' }
            Mock -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' {
                [pscustomobject]@{ ExitCode = 7; DurationSec = 2.25; Completed = $true }
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
                [pscustomobject]@{ ExitCode = 0; DurationSec = 1.0; Completed = $true }
            }
            Mock -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' { }

            Start-InteractiveTranscript -Command 'htop' -Path (Join-Path -Path $TestDrive -ChildPath 'b.cast')

            Should -Invoke -CommandName Start-BsnUnixPtyRecording -ModuleName 'Bsn.Host' -Times 1 -Exactly -Scope It -ParameterFilter { $Command -eq 'htop' }
        }

        It 'propagates the recorded exit code to LASTEXITCODE' {
            Mock -CommandName Get-BsnOperatingSystem -ModuleName 'Bsn.Host' { 'Windows' }
            Mock -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' {
                [pscustomobject]@{ ExitCode = 42; DurationSec = 1.0; Completed = $true }
            }

            Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'c.cast')
            $LASTEXITCODE | Should -Be 42
        }
    }

    Context 'support for -WhatIf' {
        It 'records nothing under -WhatIf' {
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
