<#
.SYNOPSIS
    Validates the environment before an interactive recording starts.

.DESCRIPTION
    Implements the RFC 421 platform contract with explicit messages:
    - Windows requires Windows 10 1809 / Server 2019+ (pseudo-console);
      older versions fail with a platform-not-supported error.
    - Unix requires the script(1) utility on PATH.
    - Redirected standard I/O (CI, scripted harnesses) produces a warning,
      because Windows may route the recorded process output around the
      pseudo-console.
    - Non-console hosts produce a warning.

    Kept as a separate private function so it can be unit tested and
    mocked independently of the engines.
#>
function Test-BsnRecordingEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Bsn.Common.BsnOperatingSystem]$Platform
    )

    if ($Platform -eq [Bsn.Common.BsnOperatingSystem]::Unknown) {
        throw 'Interactive transcripts are not supported on this platform (detected Unknown).'
    }

    if ($Platform -eq [Bsn.Common.BsnOperatingSystem]::Windows) {
        $osVersion = [System.Environment]::OSVersion.Version
        if (($osVersion.Major -lt 10) -or (($osVersion.Major -eq 10) -and ($osVersion.Build -lt 17763))) {
            throw ('Interactive transcripts on Windows require Windows 10 1809 / Windows Server 2019 or newer for pseudo-console support (detected {0}).' -f $osVersion)
        }
    }
    else {
        $scriptTool = Get-Command -Name 'script' -ErrorAction 'SilentlyContinue'
        if (-not $scriptTool) {
            throw 'Interactive transcripts on Unix require the script(1) utility, which was not found on PATH. Install it (for example util-linux on Linux, BSD userland on macOS) and retry.'
        }
    }

    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        Write-Warning -Message 'The calling process has redirected standard I/O. The recorded process output may bypass the pseudo-console; run Start-InteractiveTranscript from an interactive console session for full capture.'
    }

    if ($Host.Name -ne 'ConsoleHost') {
        Write-Warning -Message ("The current host '{0}' may not support interactive terminal recording; recording is designed for the console host." -f $Host.Name)
    }
}
