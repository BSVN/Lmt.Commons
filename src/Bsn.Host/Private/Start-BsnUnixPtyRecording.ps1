<#
.SYNOPSIS
    Records a command inside a Unix pseudo-terminal via script(1) to a cast file.

.DESCRIPTION
    Uses the system script(1) utility, which runs the command inside a
    pseudo-terminal, proxies it to the real terminal and logs the stream:

    - util-linux script (most Linux distributions): records with exact
      timing (--log-timing/--log-out) which is then converted to asciicast v2.
    - BSD script (macOS): records the raw stream only; timestamps are
      approximated by spreading line events across the measured duration.

    The script process is monitored in a polling loop; creating StopFilePath
    on disk (the Stop-InteractiveTranscript signaling channel) terminates it
    and finalizes the recording.

    Input recording is not supported on Unix in this release; a warning is
    emitted when -RecordInput is requested.

    -AuditMetadata is the recording's capture-time audit metadata. It is
    passed on to the cast header's "bsn" block; see AuditMetadata.

.PARAMETER Command
    Command to record. Omit it to record the default interactive shell.

.PARAMETER CastPath
    Path of the cast file to write.

.PARAMETER RecordInput
    Requested input recording. Not supported on Unix: a warning is
    emitted and only terminal output is recorded.

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
    AuditMetadata object; Start-InteractiveTranscript creates one per
    recording. Omit it to leave the block out.
#>
function Start-BsnUnixPtyRecording {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Confirmation is owned by the public Start-InteractiveTranscript cmdlet.')]
    [CmdletBinding()]
    param(
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [string]$CastPath,

        [switch]$RecordInput,

        [string]$ShellName = 'shell',

        [string]$StopFilePath,

        [ValidateSet(2, 3)]
        [int]$CastVersion = 2,

        # Capture-time audit metadata, written into the header's "bsn" block.
        [Bsn.Host.Interop.AuditMetadata]$AuditMetadata
    )

    $scriptTool = Get-Command -Name 'script' -ErrorAction 'SilentlyContinue'
    if (-not $scriptTool) {
        throw ('Interactive transcripts on Unix require the script(1) utility, which was not found on PATH. Detected platform: {0}. Install it (for example util-linux on Linux, BSD userland on macOS) and retry.' -f (Get-BsnOperatingSystem))
    }

    if ($RecordInput.IsPresent) {
        Write-Warning -Message 'Recording keyboard input is not supported on Unix platforms yet; only terminal output is recorded.'
    }

    $width = 80
    $height = 24
    try {
        $tputColumns = (& tput cols 2>$null)
        if ($tputColumns) { $width = [int]$tputColumns }
    }
    catch {
        Write-Verbose -Message ("Could not query terminal width: {0}" -f $_.Exception.Message)
    }
    try {
        $tputLines = (& tput lines 2>$null)
        if ($tputLines) { $height = [int]$tputLines }
    }
    catch {
        Write-Verbose -Message ("Could not query terminal height: {0}" -f $_.Exception.Message)
    }

    # util-linux script supports exact timing logs; BSD script does not.
    $scriptHelp = (& $scriptTool.Source --help 2>&1 | Out-String)
    $supportsTiming = $scriptHelp -match '--log-timing'

    $temporaryPaths = @()
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $exitCode = 0
    $stoppedByRequest = $false
    try {
        $recordedCommand = if ($Command) { $Command } else { Get-BsnDefaultShell }

        $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $processInfo.FileName = $scriptTool.Source
        $processInfo.UseShellExecute = $false

        if ($supportsTiming) {
            $timingPath = [System.IO.Path]::GetTempFileName()
            $outputPath = [System.IO.Path]::GetTempFileName()
            $temporaryPaths = @($timingPath, $outputPath)

            # The invocation shape depends on the installed script(1): probe it
            # (util-linux 2.39+/2.41 reject the positional typescript file that
            # older releases accept - see Resolve-BsnScriptInvocation).
            $processInfo.Arguments = Resolve-BsnScriptInvocation -ScriptPath $scriptTool.Source -Command $recordedCommand -TimingPath $timingPath -OutputPath $outputPath
        }
        else {
            $rawPath = [System.IO.Path]::GetTempFileName()
            $temporaryPaths = @($rawPath)

            if ($Command) {
                $processInfo.Arguments = ('-q "{0}" /bin/sh -c "{1}"' -f $rawPath, $Command)
            }
            else {
                $processInfo.Arguments = ('-q "{0}" "{1}"' -f $rawPath, (Get-BsnDefaultShell))
            }
        }

        Write-Verbose -Message ("Recording via: {0} {1}" -f $processInfo.FileName, $processInfo.Arguments)
        $recordingProcess = [System.Diagnostics.Process]::Start($processInfo)
        try {
            while (-not $recordingProcess.HasExited) {
                if ($StopFilePath -and (Test-Path -LiteralPath $StopFilePath)) {
                    $stoppedByRequest = $true
                    $recordingProcess.Kill()
                    $recordingProcess.WaitForExit(5000) | Out-Null
                    break
                }
                Start-Sleep -Milliseconds 200
            }
            $exitCode = $recordingProcess.ExitCode
        }
        finally {
            if (-not $recordingProcess.HasExited) {
                $recordingProcess.Kill()
            }
            $recordingProcess.Dispose()
        }
        $stopwatch.Stop()

        # The converter owns the header, so the audit metadata is passed to it as-is.
        if ($supportsTiming) {
            ConvertTo-BsnAsciicast -OutputPath $outputPath -TimingPath $timingPath -CastPath $CastPath -Width $width -Height $height -ShellName $ShellName -CastVersion $CastVersion -ExitCode $exitCode -AuditMetadata $AuditMetadata
        }
        else {
            ConvertTo-BsnAsciicast -OutputPath $temporaryPaths[0] -CastPath $CastPath -Width $width -Height $height -DurationSec $stopwatch.Elapsed.TotalSeconds -ShellName $ShellName -CastVersion $CastVersion -ExitCode $exitCode -AuditMetadata $AuditMetadata
        }
    }
    finally {
        $stopwatch.Stop()
        foreach ($temporaryPath in $temporaryPaths) {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction 'SilentlyContinue'
            }
        }
    }

    return [pscustomobject]@{
        ExitCode         = $exitCode
        DurationSec      = $stopwatch.Elapsed.TotalSeconds
        StoppedByRequest = $stoppedByRequest
        Completed        = $true
    }
}
