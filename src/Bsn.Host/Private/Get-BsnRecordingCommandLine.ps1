<#
.SYNOPSIS
    Builds the Windows process command line used for a recording.

.DESCRIPTION
    Wraps the recorded command in 'cmd.exe /d /c' so arbitrary command
    lines can be recorded. Without -Command, the default interactive shell
    is returned; when that shell is pwsh or powershell, Bsn.Host is
    auto-imported into the nested session so Stop-InteractiveTranscript is
    available inside the recording.
#>
function Get-BsnRecordingCommandLine {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Command
    )

    if ($Command) {
        return ('cmd.exe /d /c "{0}"' -f $Command)
    }

    $shellPath = Get-BsnDefaultShell
    if ($shellPath -match ' ') {
        $shellPath = '"{0}"' -f $shellPath
    }

    if ($shellPath -match '(pwsh|powershell)("?)$') {
        return ('{0} -NoLogo -NoExit -Command "Import-Module Bsn.Host"' -f $shellPath)
    }

    return $shellPath
}
