using module Bsn.Common

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
    that plays back with Show-InteractiveTranscript, 'asciinema play' or
    any asciicast v2 player.

    Full-screen TUI applications (sconfig, vim, htop, nmtui, ...) are fully
    captured because the recorded process is attached to a real
    pseudo-terminal. Console resizes that happen while recording are
    forwarded to the pseudo-console and recorded as 'r' events.

    START/STOP WORKFLOW

    Without -Command, the cmdlet starts a recorded interactive shell
    (pwsh if available, otherwise powershell/cmd.exe on Windows, $SHELL on
    Unix). On Windows the nested pwsh auto-imports Bsn.Host, so the
    Start-Transcript-like workflow is:

        Start-InteractiveTranscript     # enter the recorded session
        <anything, including TUI apps>  # everything is recorded
        Stop-InteractiveTranscript      # finalize and return to the outer shell

    Typing 'exit' in the nested shell finalizes the recording as well, and
    Ctrl+C aborts it while keeping the cast file playable (it is written
    incrementally). With -Command, recording ends when the command exits.

    What a module cannot do - and why: transparently recording the CURRENT
    outer PowerShell session (the way Start-Transcript does) would require
    intercepting the host's console I/O (CONIN$/CONOUT$ on Windows,
    /dev/tty on Unix). PowerShell exposes no public hook, event or handler
    for that at the C# API level; only the host process itself can (the
    subject of PowerShell-RFC#421). The recorded nested session is the
    closest a PowerShell Gallery module can deliver.

.PARAMETER Command
    The command line to record. When omitted, an interactive shell session
    is recorded. Recording stops when the command or shell exits, when
    Stop-InteractiveTranscript runs inside it, or on Ctrl+C.

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
        propagated to $LASTEXITCODE), DurationSec, StoppedByRequest and
        VideoPath (the rendered video file, or $null when recording
        asciicast only or when rendering was skipped).

.EXAMPLE
    Start-InteractiveTranscript

    Enters a recorded interactive shell session (Start-Transcript-like
    workflow). Run Stop-InteractiveTranscript (or 'exit') to finalize.

.EXAMPLE
    Start-InteractiveTranscript -Command 'sconfig'

    Records the full-screen sconfig tool; recording ends when it exits.

.EXAMPLE
    Start-InteractiveTranscript -Command 'nmtui' -Path .\demo\intro -RecordingFormat WebM -RecordIdleTimeLimit 5

    Records nmtui, compresses idle gaps longer than five seconds, and
    renders a .webm video (requires agg and ffmpeg on PATH).

.NOTES
    Environment constraints are checked before recording starts and
    reported explicitly:
    - Windows requires Windows 10 1809 / Server 2019+ (pseudo-console); on
      older versions the cmdlet fails with a platform-not-supported error.
    - Unix requires the script(1) utility on PATH.
    - When the calling process has redirected standard I/O (CI, scripted
      harnesses), a warning is emitted: Windows may route the recorded
      process output around the pseudo-console. Run from an interactive
      console session for full capture.
    - Non-console hosts receive a warning that recording may not work.

    Implements https://github.com/PowerShell/PowerShell/issues/28353
    following the parameter and format semantics of PowerShell-RFC#421 at
    module scope.
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

        # Environment constraint checks with explicit messages (RFC 421 platform contract).
        Test-BsnRecordingEnvironment -Platform $platform

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

        # Stop signaling channel: Stop-InteractiveTranscript (running inside the recorded
        # session) creates this file; the recording engine finalizes and returns.
        $previousStopFile = $env:BsnHostRecordingStopFile
        $stopFilePath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('BsnHostRecordingStop_{0}.stop' -f [guid]::NewGuid().ToString('N'))
        $env:BsnHostRecordingStopFile = $stopFilePath

        try {
            if ($platform -eq [BsnOperatingSystem]::Windows) {
                $commandLine = Get-BsnRecordingCommandLine -Command $Command
                $result = Start-BsnWindowsPtyRecording -CommandLine $commandLine -CastPath $resolvedCastPath -RecordInput:$RecordInput.IsPresent -ShellName $shellName -StopFilePath $stopFilePath
            }
            else {
                # Linux and macOS are both Unix: they share the script(1)-based engine,
                # which picks util-linux (exact timing) or BSD script (approximated) itself.
                $result = Start-BsnUnixPtyRecording -Command $Command -CastPath $resolvedCastPath -RecordInput:$RecordInput.IsPresent -ShellName $shellName -StopFilePath $stopFilePath
            }
        }
        finally {
            $env:BsnHostRecordingStopFile = $previousStopFile
            if (Test-Path -LiteralPath $stopFilePath) {
                Remove-Item -LiteralPath $stopFilePath -Force -ErrorAction 'SilentlyContinue'
            }
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
            PSTypeName       = 'Bsn.Host.InteractiveTranscript'
            CastPath         = $resolvedCastPath
            ExitCode         = $result.ExitCode
            DurationSec      = [math]::Round($result.DurationSec, 3)
            StoppedByRequest = $result.StoppedByRequest
            VideoPath        = $videoPath
        }
    }
}
