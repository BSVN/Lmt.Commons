<#
.SYNOPSIS
    Builds the Windows process command line used for a recording.

.DESCRIPTION
    When -Command is given, the command is wrapped in pwsh -EncodedCommand
    (Base64-encoded UTF-16LE) instead of cmd.exe /d /c. This avoids all
    cmd.exe metacharacter issues (|, &, <, >, ^, quotes) that mangle the
    recorded command (issue #7): the exact command text is preserved
    bit-for-bit through the encoding.

    The wrapper bootstraps the console codepage to UTF-8 before the
    recorded command runs (issue #5, second root cause): conhost decodes
    a child's stdout BYTES using the console output codepage, and a fresh
    pseudo console starts with the OEM codepage (e.g. 437), not UTF-8.
    TUIs that write UTF-8 bytes directly to the console handle (Go/Bubble
    Tea applications such as OpenCode, Node raw writes, 'cmd /c type') are
    then mangled before our recorder sees a single byte - every box-drawing
    character becomes three CP-decoded characters (e.g. U+2500 'E2 94 80'
    becomes 'Gamma-ohmega-acute' in CP437). pwsh's own output is immune
    (it writes through WriteConsoleW), which is why synthetic pwsh probes
    passed while real byte-writing TUIs produced mojibake. Setting
    [Console]::OutputEncoding / InputEncoding to UTF-8 is the programmatic
    equivalent of 'chcp 65001' and fixes the decoding for the whole
    recorded session, including applications started later inside it.

    Without -Command, the default interactive shell is returned; when that
    shell is pwsh or powershell, the same codepage bootstrap runs first,
    Bsn.Host is auto-imported into the nested session so
    Stop-InteractiveTranscript is available inside the recording, and the
    recording-aware prompt is installed when requested.
#>
function Get-BsnRecordingCommandLine {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Command,

        [switch]$ShowRecordingIndicator
    )

    # ASCII-only bootstrap (this file stays ASCII per repo policy): UTF-8
    # console codepage for the recorded session (issue #5, conhost CP decode).
    $codePageBootstrap = '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; [Console]::InputEncoding = [System.Text.Encoding]::UTF8;'

    if ($Command) {
        # Base64-encode the command to survive the CreateProcess command line
        # without any shell metacharacter interpretation (issue #7).
        $shellPath = Get-BsnDefaultShell
        if ($shellPath -match ' ') {
            $shellPath = '"{0}"' -f $shellPath
        }
        $wrappedCommand = $codePageBootstrap + ' ' + $Command
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($wrappedCommand))
        return ('{0} -NoProfile -EncodedCommand {1}' -f $shellPath, $encoded)
    }

    $shellPath = Get-BsnDefaultShell
    if ($shellPath -match ' ') {
        $shellPath = '"{0}"' -f $shellPath
    }

    if ($shellPath -match '(pwsh|powershell)(\.exe)?("?)$') {
        $nestedCommand = $codePageBootstrap + ' Import-Module Bsn.Host'
        if ($ShowRecordingIndicator.IsPresent) {
            # Recording-aware prompt for the nested session; the glyph is built from
            # its code point so this file stays ASCII-only.
            $nestedCommand = $codePageBootstrap + ' Import-Module Bsn.Host; function prompt { ''{0} REC PS {1}> '' -f [char]0x23FA, (Get-Location).Path }'
        }
        return ('{0} -NoLogo -NoExit -Command "{1}"' -f $shellPath, $nestedCommand)
    }

    # Non-PowerShell default shells cannot run the pwsh bootstrap inline; the
    # console keeps its OEM codepage (byte-writing TUIs need 'chcp 65001' run
    # manually inside them on OEM-codepage-decoding conhosts).
    return $shellPath
}
