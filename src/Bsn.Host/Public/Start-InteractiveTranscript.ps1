<#
.SYNOPSIS
    Records an interactive terminal session - including full-screen TUI
    applications - to a replayable asciicast v2 file, optionally rendered
    as video.

.DESCRIPTION
    Start-InteractiveTranscript fills the gap where Start-Transcript cannot
    help: it records the terminal itself, not just the PowerShell pipeline.
    The recorded command runs inside a pseudo-terminal (ConPTY on Windows,
    script(1) on Linux/macOS) whose output stream is proxied to the real
    console and teed, with timestamps, into an asciicast v2 (.cast) file
    that plays back with 'asciinema play' or any asciicast v2 player.

    Full-screen TUI applications (sconfig, vim, htop, nmtui, ...) are fully
    captured because the recorded process is attached to a real
    pseudo-terminal. Console resizes that happen while recording are
    forwarded to the pseudo-console and recorded as 'r' events.

    When -Command is omitted, an interactive shell is recorded (pwsh if
    available, otherwise powershell/cmd.exe on Windows, $SHELL on Unix).
    Recording ends when the recorded process exits.

    Implements the community request tracked in
    https://github.com/PowerShell/PowerShell/issues/28353 and follows the
    parameter and format semantics of the corresponding RFC
    (PowerShell-RFC#421, Terminal Session Recording) at the scope a
    PowerShell Gallery module can deliver: command-scoped recording rather
    than transparent whole-host capture (which only the host itself could
    do). The RFC's alternate-proposal cmdlet name is used.

.PARAMETER Command
    The command line to record. When omitted, an interactive shell session
    is recorded. Recording stops when the command or shell exits.

.PARAMETER Path
    The asciicast v2 (.cast) file to write. Defaults to
    InteractiveTranscript_<timestamp>.cast in the temporary directory. The
    cast file is always written and is the source of truth; any video file
    is a render product of it (RFC 421).

.PARAMETER RecordingFormat
    The deliverable format (RFC 421):
    - Asciicast (default): write only the .cast file.
    - Gif: render an animated GIF via the external 'agg' renderer.
    - WebM / Mp4: render via 'agg' and transcode via 'ffmpeg'.
    Video output derives its file name from -Path by replacing the
    extension. When a required external tool is not on PATH, a warning is
    emitted and the .cast file remains complete and valid.

.PARAMETER RecordInput
    Also records keystrokes sent to the recorded process as 'i' events.
    Disabled by default: captured input includes passwords and other
    secrets typed at hidden prompts (RFC 421 security note); when enabled,
    the fact is recorded in the cast file header. Windows only in this
    release.

.PARAMETER RecordIdleTimeLimit
    When greater than zero (seconds), idle periods between events longer
    than this limit are time-compressed in the cast timing so playback and
    video renders of long, idle-heavy sessions stay watchable (RFC 421).
    Zero (default) keeps original timing.

.PARAMETER Force
    Overwrites the cast file if it already exists.

.INPUTS
    None

.OUTPUTS
    Bsn.Host.InteractiveTranscript
        An object with CastPath, ExitCode (of the recorded process, also
        propagated to $LASTEXITCODE), DurationSec and VideoPath (the
        rendered video file, or $null when recording asciicast only or when
        rendering was skipped).

.EXAMPLE
    Start-InteractiveTranscript -Command 'sconfig'

    Records the full-screen sconfig tool to a cast file in the temporary
    directory and returns the recording summary.

.EXAMPLE
    $recording = Start-InteractiveTranscript -Path .\audit\session01.cast

    Records an interactive shell session; type 'exit' in the nested shell
    to stop recording.

.EXAMPLE
    Start-InteractiveTranscript -Command 'vim notes.txt' -Path .\notes.cast -Force

    Records a vim session, overwriting any existing cast file. Replay it
    later with: asciinema play .\notes.cast

.EXAMPLE
    Start-InteractiveTranscript -Command 'nmtui' -Path .\demo\intro -RecordingFormat WebM -RecordIdleTimeLimit 5

    Records nmtui, compresses idle gaps longer than five seconds for
    watchable playback, and renders a .webm video (requires agg and ffmpeg
    on PATH; otherwise the .cast file stands alone).

.NOTES
    The cast file is written incrementally while the session runs. On
    Windows the ConPTY engine requires Windows 10 1809+; on Unix the
    script(1) utility is required (timing-exact output on util-linux,
    approximated timestamps on BSD/macOS in this release).

    Run from an interactive console session. When the calling PowerShell
    process itself has redirected standard I/O (for example inside CI or
    when scripted through a harness), Windows may route the recorded
    process output around the pseudo-console; recording is designed for,
    and validated in, interactive terminal sessions.
#>
function Start-InteractiveTranscript {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Position = 0)]
        [string]$Command,

        [string]$Path,

        [ValidateSet('Asciicast', 'Gif', 'WebM', 'Mp4')]
        [string]$RecordingFormat = 'Asciicast',

        [ValidateRange(0, [int]::MaxValue)]
        [int]$RecordIdleTimeLimit = 0,

        [switch]$RecordInput,

        [switch]$Force
    )

    process {
        $platform = Get-BsnOperatingSystem
        if ($platform -eq 'Unknown') {
            throw ("Interactive transcripts are not supported on this platform ('{0}')." -f $platform)
        }

        if (-not $Path) {
            $Path = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('InteractiveTranscript_{0}.cast' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        }

        $castDirectory = Split-Path -Parent -Path $Path
        if ($castDirectory -and (-not (Test-Path -LiteralPath $castDirectory))) {
            throw ("The directory '{0}' does not exist." -f $castDirectory)
        }

        if ((Test-Path -LiteralPath $Path) -and -not $Force.IsPresent) {
            throw ("The cast file '{0}' already exists. Use -Force to overwrite it." -f $Path)
        }

        $resolvedCastPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)

        if (-not $PSCmdlet.ShouldProcess($resolvedCastPath, 'Record interactive terminal session')) {
            return
        }

        $shellName = if ($Command) {
            ($Command -split '\s+')[0]
        }
        else {
            Split-Path -Leaf -Path (Get-BsnDefaultShell)
        }

        if ($platform -eq 'Windows') {
            $commandLine = Get-BsnRecordingCommandLine -Command $Command
            $result = Start-BsnWindowsPtyRecording -CommandLine $commandLine -CastPath $resolvedCastPath -RecordInput:$RecordInput.IsPresent -ShellName $shellName
        }
        else {
            $result = Start-BsnUnixPtyRecording -Command $Command -CastPath $resolvedCastPath -RecordInput:$RecordInput.IsPresent -ShellName $shellName
        }

        if ($RecordIdleTimeLimit -gt 0) {
            Optimize-BsnCastIdleTime -Path $resolvedCastPath -LimitSec $RecordIdleTimeLimit
        }

        $videoPath = $null
        if ($RecordingFormat -ne 'Asciicast') {
            $videoPath = Invoke-BsnCastRender -CastPath $resolvedCastPath -Format $RecordingFormat
        }

        # Propagate the recorded process exit code like a native command would.
        Set-Variable -Name 'LASTEXITCODE' -Scope 'Global' -Value $result.ExitCode

        [pscustomobject]@{
            PSTypeName  = 'Bsn.Host.InteractiveTranscript'
            CastPath    = $resolvedCastPath
            ExitCode    = $result.ExitCode
            DurationSec = [math]::Round($result.DurationSec, 3)
            VideoPath   = $videoPath
        }
    }
}
