<#
.SYNOPSIS
    Builds the Windows process command line used for a recording.

.DESCRIPTION
    Wraps the recorded command in 'cmd.exe /d /c' so arbitrary command
    lines can be recorded. Without -Command, the default interactive shell
    (quoted when its path contains spaces) is returned for direct
    recording.
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
        return ('"{0}"' -f $shellPath)
    }

    return $shellPath
}
