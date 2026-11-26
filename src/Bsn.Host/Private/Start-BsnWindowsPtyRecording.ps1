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

    The audit metadata parameters (-SessionId, -RecordedBy, -ComputerName,
    -UserName, -ProcessId, -PSVersion, -Edition) take the same names here
    as on the Unix engine; see ConvertTo-BsnCastHeaderBlock for what each
    one means.

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

.PARAMETER SessionId
    Audit metadata, written into the header's "bsn" block.

.PARAMETER RecordedBy
    Audit metadata, written into the header's "bsn" block.

.PARAMETER ComputerName
    Audit metadata, written into the header's "bsn" block.

.PARAMETER UserName
    Audit metadata, written into the header's "bsn" block.

.PARAMETER ProcessId
    Audit metadata, written into the header's "bsn" block.

.PARAMETER PSVersion
    Audit metadata, written into the header's "bsn" block.

.PARAMETER Edition
    Audit metadata, written into the header's "bsn" block.
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

        # Audit metadata, written into the header's "bsn" block.
        [string]$SessionId = '',

        [string]$RecordedBy = '',

        [string]$ComputerName = '',

        [string]$UserName = '',

        [int]$ProcessId = 0,

        [string]$PSVersion = '',

        [string]$Edition = ''
    )

    # The engine is compiled code, so the named fields cross the language
    # boundary as one pre-serialized JSON value. The helper defines the
    # block's shape; an empty result leaves the block out of the header.
    $headerMetadata = ConvertTo-BsnCastHeaderBlock `
        -SessionId $SessionId -RecordedBy $RecordedBy -ComputerName $ComputerName -UserName $UserName `
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
