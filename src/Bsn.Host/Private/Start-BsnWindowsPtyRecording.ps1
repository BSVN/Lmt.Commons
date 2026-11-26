<#
.SYNOPSIS
    Records a command inside a Windows pseudo-console (ConPTY) to a cast file.

.DESCRIPTION
    Thin wrapper around the compiled Bsn.Host engine (src/Bsn.Host.csproj,
    loaded through the shared Bsn.Common loader instead of RequiredAssemblies):
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

    The capture-time audit metadata parameters (-SessionId, -RecordedBy,
    -Machine, -Username, -ProcessId, -PSVersion, -Edition) are written
    into the cast header's "bsn" block. They take the same names here as
    on the Unix engine and on ConvertTo-BsnTranscript, which reads the
    block back.
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

        [string]$StopFilePath,

        [ValidateSet(2, 3)]
        [int]$CastVersion = 2,

        # Capture-time audit metadata (the cast header's "bsn" block).
        [string]$SessionId = '',

        [string]$RecordedBy = '',

        [string]$Machine = '',

        [string]$Username = '',

        [int]$ProcessId = 0,

        [string]$PSVersion = '',

        [string]$Edition = ''
    )

    # The engine is compiled code, so the named fields cross the language
    # boundary as one pre-serialized JSON value. The helper defines the
    # block's shape; an empty result leaves the block out of the header.
    $headerMetadata = ConvertTo-BsnCastHeaderBlock `
        -SessionId $SessionId -RecordedBy $RecordedBy -Machine $Machine -Username $Username `
        -ProcessId $ProcessId -PSVersion $PSVersion -Edition $Edition

    try {
        $engineResult = [Bsn.Host.Interop.PtyRecorder]::Run($CommandLine, $CastPath, $RecordInput.IsPresent, $ShellName, $StopFilePath, $CastVersion, $HeaderMetadata)
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
