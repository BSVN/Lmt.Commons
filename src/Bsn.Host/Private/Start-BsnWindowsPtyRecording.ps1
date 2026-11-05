<#
.SYNOPSIS
    Records a command inside a Windows pseudo-console (ConPTY) to a cast file.

.DESCRIPTION
    Thin wrapper around the compiled Bsn.Host engine (src/Bsn.Host.csproj,
    loaded via the module manifest's RequiredAssemblies):
    - creates a pseudo-console and starts the command attached to it,
    - proxies raw console input into the pseudo-console,
    - tees the VT output stream to the real console and, with timestamps,
      into an asciicast v2 file,
    - resizes the pseudo-console and records 'r' events on console resizes,
    - finalizes the recording when the process exits, when StopFilePath
      appears on disk (the Stop-InteractiveTranscript signaling channel),
      or on Ctrl+C (the cast file is written incrementally).

    The engine requires Windows 10 1809+ (CreatePseudoConsole); the public
    cmdlet checks this before dispatching.
#>
function Start-BsnWindowsPtyRecording {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Confirmation is owned by the public Start-InteractiveTranscript cmdlet.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandLine,

        [Parameter(Mandatory = $true)]
        [string]$CastPath,

        [switch]$RecordInput,

        [string]$ShellName = 'shell',

        [string]$StopFilePath
    )

    try {
        $engineResult = [Bsn.Host.Interop.PtyRecorder]::Run($CommandLine, $CastPath, $RecordInput.IsPresent, $ShellName, $StopFilePath)
    }
    catch [System.Runtime.InteropServices.EntryPointNotFoundException] {
        throw 'Interactive transcripts on Windows require pseudo-console support (Windows 10 1809 or newer).'
    }

    return [pscustomobject]@{
        ExitCode         = $engineResult.ExitCode
        DurationSec      = $engineResult.DurationSec
        StoppedByRequest = $engineResult.StoppedByRequest
        Completed        = $true
    }
}
