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

        It 'writes an error when remoting fails' {
            Mock -CommandName Invoke-Command -ModuleName 'Bsn.SystemManagement' { throw 'remoting unavailable' }
            { Suspend-Computer -ComputerName 'REMOTE-02' -Force -ErrorAction 'Stop' } | Should -Throw
        }
    }
}
