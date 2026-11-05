<#
.SYNOPSIS
    Builds the Windows process command line used for a recording.

.DESCRIPTION
    Wraps the recorded command in 'cmd.exe /d /c' so arbitrary command
    lines can be recorded. Without -Command, the default interactive shell
    is returned; when that shell is pwsh or powershell, Bsn.Host is
    auto-imported into the nested session so Stop-InteractiveTranscript is
    available inside the recording. With -ShowRecordingIndicator, the
    nested session additionally gets a recording-aware prompt
    ([char]0x23FA + ' REC PS <path>> ').
#>
function Get-BsnRecordingCommandLine {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Command,

        [switch]$ShowRecordingIndicator
    )

    if ($Command) {
        return ('cmd.exe /d /c "{0}"' -f $Command)
    }

    $shellPath = Get-BsnDefaultShell
    if ($shellPath -match ' ') {
        $shellPath = '"{0}"' -f $shellPath
    }

    if ($shellPath -match '(pwsh|powershell)(\.exe)?("?)$') {
        $nestedCommand = 'Import-Module Bsn.Host'
        if ($ShowRecordingIndicator.IsPresent) {
            # Recording-aware prompt for the nested session; the glyph is built from
            # its code point so this file stays ASCII-only.
            $nestedCommand = 'Import-Module Bsn.Host; function prompt { ''{0} REC PS {1}> '' -f [char]0x23FA, (Get-Location).Path }'
        }
        return ('{0} -NoLogo -NoExit -Command "{1}"' -f $shellPath, $nestedCommand)
    }

    return $shellPath
}
