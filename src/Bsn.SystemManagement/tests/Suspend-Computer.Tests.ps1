[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingComputerNameHardcoded', '', Justification = 'Test fixtures use synthetic computer names.')]
param()

BeforeAll {
    $moduleRoot = Split-Path -Parent -Path $PSScriptRoot
    # Make the repo sibling module Bsn.Common resolvable for RequiredModules validation.
    $env:PSModulePath = '{0}{1}{2}' -f (Split-Path -Parent -Path $moduleRoot), [System.IO.Path]::PathSeparator, $env:PSModulePath
    $manifestPath = Join-Path -Path $moduleRoot -ChildPath 'Bsn.SystemManagement.psd1'
    Import-Module -Name $manifestPath -Force -ErrorAction 'Stop'
}

Describe 'Suspend-Computer' {
    Context 'parameter set' {
        It 'takes the computer name as a string array' {
            (Get-Command -Name 'Suspend-Computer').Parameters['ComputerName'].ParameterType | Should -Be ([string[]])
        }

        It 'supports WhatIf and Confirm' {
            $command = Get-Command -Name 'Suspend-Computer'
            $command.Parameters.ContainsKey('WhatIf') | Should -BeTrue
            $command.Parameters.ContainsKey('Confirm') | Should -BeTrue
        }
    }

    Context 'local suspend' {
        BeforeEach {
            Mock -CommandName Invoke-BsnLocalSuspend -ModuleName 'Bsn.SystemManagement' { }
            Mock -CommandName Test-BsnLocalComputer -ModuleName 'Bsn.SystemManagement' { $true }
        }

        It 'suspends the local computer when no computer name is given' {
            Suspend-Computer -Force
            Should -Invoke -CommandName Invoke-BsnLocalSuspend -ModuleName 'Bsn.SystemManagement' -Times 1 -Exactly -Scope It
        }

        It 'recognizes an explicitly named local computer' {
            Suspend-Computer -ComputerName 'localhost' -Force
            Should -Invoke -CommandName Test-BsnLocalComputer -ModuleName 'Bsn.SystemManagement' -Times 1 -Exactly -Scope It -ParameterFilter { $ComputerName -eq 'localhost' }
        }

        It 'passes the Hibernate switch through to the suspend action' {
            Suspend-Computer -Hibernate -Force
            Should -Invoke -CommandName Invoke-BsnLocalSuspend -ModuleName 'Bsn.SystemManagement' -Times 1 -Exactly -Scope It -ParameterFilter { $Hibernate.IsPresent -eq $true }
        }

        It 'does not suspend anything under -WhatIf' {
            Suspend-Computer -WhatIf
            Should -Invoke -CommandName Invoke-BsnLocalSuspend -ModuleName 'Bsn.SystemManagement' -Times 0 -Exactly -Scope It
        }
    }

    Context 'remote suspend' {
        BeforeEach {
            Mock -CommandName Test-BsnLocalComputer -ModuleName 'Bsn.SystemManagement' { $false }
            Mock -CommandName Invoke-Command -ModuleName 'Bsn.SystemManagement' { }
        }

        It 'uses PowerShell remoting for remote computers' {
            Suspend-Computer -ComputerName 'REMOTE-01' -Force
            Should -Invoke -CommandName Invoke-Command -ModuleName 'Bsn.SystemManagement' -Times 1 -Exactly -Scope It
        }

        It 'runs the grace period before reaching the remote computer (issue #17)' {
            # https://github.com/BSVN/Lmt.Commons/issues/17
            Mock -CommandName Wait-BsnSuspendGracePeriod -ModuleName 'Bsn.SystemManagement' { }
            Suspend-Computer -ComputerName 'REMOTE-03' -After 30 -Force
            Should -Invoke -CommandName Wait-BsnSuspendGracePeriod -ModuleName 'Bsn.SystemManagement' -Times 1 -Exactly -Scope It `
                -ParameterFilter { $Seconds -eq 30 }
            Should -Invoke -CommandName Invoke-Command -ModuleName 'Bsn.SystemManagement' -Times 1 -Exactly -Scope It
        }

        It 'writes an error when remoting fails' {
            Mock -CommandName Invoke-Command -ModuleName 'Bsn.SystemManagement' { throw 'remoting unavailable' }
            { Suspend-Computer -ComputerName 'REMOTE-02' -Force -ErrorAction 'Stop' } | Should -Throw
        }
    }

    Context 'delayed suspend (-After)' {
        # https://github.com/BSVN/Lmt.Commons/issues/17
        BeforeEach {
            Mock -CommandName Wait-BsnSuspendGracePeriod -ModuleName 'Bsn.SystemManagement' { }
            Mock -CommandName Invoke-BsnLocalSuspend -ModuleName 'Bsn.SystemManagement' { }
            Mock -CommandName Test-BsnLocalComputer -ModuleName 'Bsn.SystemManagement' { $true }
        }

        It 'runs the grace period with the requested -After seconds' {
            Suspend-Computer -After 5 -Force
            Should -Invoke -CommandName Wait-BsnSuspendGracePeriod -ModuleName 'Bsn.SystemManagement' -Times 1 -Exactly -Scope It `
                -ParameterFilter { $Seconds -eq 5 }
        }

        It 'defaults to an immediate suspension (grace seconds = 0)' {
            Suspend-Computer -Force
            Should -Invoke -CommandName Wait-BsnSuspendGracePeriod -ModuleName 'Bsn.SystemManagement' -Times 1 -Exactly -Scope It `
                -ParameterFilter { $Seconds -eq 0 }
        }

        It 'mentions the delay in the WhatIf description' {
            (Get-Command -Name 'Suspend-Computer').Definition | Should -Match 'power state after'
        }

        It 'rejects negative -After values through parameter validation' {
            { Suspend-Computer -After -1 -Force -ErrorAction 'Stop' } | Should -Throw
        }
    }

    Context 'grace period (Wait-BsnSuspendGracePeriod)' {
        It 'warns and sleeps for the requested seconds' {
            Mock -CommandName Start-Sleep -ModuleName 'Bsn.SystemManagement' { }
            Mock -CommandName Write-Warning -ModuleName 'Bsn.SystemManagement' { }

            & (Get-Module -Name 'Bsn.SystemManagement') { param() Wait-BsnSuspendGracePeriod -Seconds 2 }

            Should -Invoke -CommandName Start-Sleep -ModuleName 'Bsn.SystemManagement' -Times 1 -Exactly -Scope It `
                -ParameterFilter { $Seconds -eq 2 }
            Should -Invoke -CommandName Write-Warning -ModuleName 'Bsn.SystemManagement' -Times 1 -Exactly -Scope It
        }

        It 'sleeps for zero seconds when the delay is zero' {
            Mock -CommandName Start-Sleep -ModuleName 'Bsn.SystemManagement' { }
            Mock -CommandName Write-Warning -ModuleName 'Bsn.SystemManagement' { }

            & (Get-Module -Name 'Bsn.SystemManagement') { param() Wait-BsnSuspendGracePeriod -Seconds 0 }

            Should -Invoke -CommandName Start-Sleep -ModuleName 'Bsn.SystemManagement' -Times 0 -Exactly -Scope It
            Should -Invoke -CommandName Write-Warning -ModuleName 'Bsn.SystemManagement' -Times 0 -Exactly -Scope It
        }
    }
}
