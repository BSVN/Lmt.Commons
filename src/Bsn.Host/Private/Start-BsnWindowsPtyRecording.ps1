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

    -AuditMetadata is the recording's capture-time audit metadata. It is
    passed on to the cast header's "bsn" block; see BsnAuditMetadata.

.PARAMETER CommandLine
    Command line the engine runs inside the pseudo-console.

.PARAMETER CastPath
    Path of the cast file to write.

.PARAMETER RecordInput
    Also records console input as 'i' events.

.PARAMETER ShellName
    Name of the recorded command or shell, recorded in the header as
    env.SHELL and, in a v3 header, as "command". Default 'shell'.

.PARAMETER StopFilePath
    When set, creating this file ends the recording. It is the channel
    Stop-InteractiveTranscript uses from inside the recorded session.

.PARAMETER CastVersion
    Asciicast format to write: 2 (default) or 3.

.PARAMETER AuditMetadata
    Capture-time audit metadata for the cast header's "bsn" block, as a
    BsnAuditMetadata object; Start-InteractiveTranscript creates one per
    recording. Omit it to leave the block out.
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

        # Capture-time audit metadata, written into the header's "bsn" block.
        [BsnAuditMetadata]$AuditMetadata
    )

    # The engine is compiled code, so the object crosses the language
    # boundary as its JSON form. An empty string leaves the block out.
    $headerMetadata = ''
    if ($AuditMetadata) {
        $headerMetadata = $AuditMetadata.ToHeaderJson()
    }

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
