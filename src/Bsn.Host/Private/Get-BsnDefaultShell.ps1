using module Bsn.Common

<#
.SYNOPSIS
    Resolves the default interactive shell for recording.

.DESCRIPTION
    Returns the full path of the shell recorded when Start-InteractiveTranscript
    runs without -Command: pwsh when available, otherwise powershell, otherwise
    cmd.exe on Windows; $env:SHELL (or /bin/sh) on Unix.
#>
function Get-BsnDefaultShell {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ((Get-BsnOperatingSystem) -eq [BsnOperatingSystem]::Windows) {
        foreach ($shellName in @('pwsh', 'powershell')) {
            $shellCommand = Get-Command -Name $shellName -ErrorAction 'SilentlyContinue'
            if ($shellCommand) {
                return $shellCommand.Source
            }
        }

        $cmdPath = Join-Path -Path $env:SystemRoot -ChildPath 'System32\cmd.exe'
        if (Test-Path -LiteralPath $cmdPath) {
            return $cmdPath
        }
        return 'cmd.exe'
    }

    if ($env:SHELL) {
        return $env:SHELL
    }

    return '/bin/sh'
}
