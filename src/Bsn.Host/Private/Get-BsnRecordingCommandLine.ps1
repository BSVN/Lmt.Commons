<#
.SYNOPSIS
    Builds the Windows process command line used for a recording.

.DESCRIPTION
    When -Command is given, the command is wrapped in pwsh -EncodedCommand
    (Base64-encoded UTF-16LE) instead of cmd.exe /d /c. This avoids all
    cmd.exe metacharacter issues (|, &, <, >, ^, quotes) that mangle the
    recorded command (issue #7): the exact command text is preserved
    bit-for-bit through the encoding.

    Without -Command, the default interactive shell is returned; when that
    shell is pwsh or powershell, Bsn.Host is auto-imported into the nested
    session so Stop-InteractiveTranscript is available inside the recording,
    and the recording-aware prompt is installed when requested.
#>
function Get-BsnRecordingCommandLine {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Command,

        [switch]$ShowRecordingIndicator
    )

    if ($Command) {
        # Base64-encode the command to survive the CreateProcess command line
        # without any shell metacharacter interpretation (issue #7).
        $shellPath = Get-BsnDefaultShell
        if ($shellPath -match ' ') {
            $shellPath = '"{0}"' -f $shellPath
        }
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Command))
        return ('{0} -NoProfile -EncodedCommand {1}' -f $shellPath, $encoded)
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
