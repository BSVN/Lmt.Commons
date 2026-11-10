<#
.SYNOPSIS
    Stops the interactive transcript running in the current session.

.DESCRIPTION
    Finalizes the recording started by Start-InteractiveTranscript and
    returns control to the outer shell, providing the Stop-Transcript half
    of the Start-Transcript-like workflow.

    Stop-InteractiveTranscript must run INSIDE the recorded session (the
    nested shell that Start-InteractiveTranscript enters, or any child of
    it); the stop signal is passed to the recording engine through the
    BSN_HOST_RECORDING_STOP_FILE environment variable, which descendants
    inherit. On Windows the default recorded shell (pwsh) imports Bsn.Host
    automatically, so the cmdlet is available out of the box. Typing 'exit'
    in the recorded shell finalizes the recording as well.

.EXAMPLE
    Start-InteractiveTranscript
    PS> <work, TUI apps, ...>
    PS> Stop-InteractiveTranscript

    Records everything until Stop-InteractiveTranscript finalizes the cast
    file and returns to the outer PowerShell session.

.INPUTS
    None

.OUTPUTS
    None

.NOTES
    When no recording is active in this session, the cmdlet throws an
    explanatory error instead of touching anything.

.LINK
    https://bsvn.github.io/Lmt.Commons/en-US/Stop-InteractiveTranscript.html
#>
function Stop-InteractiveTranscript {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    process {
        $stopFilePath = $env:BsnHostRecordingStopFile
        if (-not $stopFilePath) {
            throw 'No interactive transcript is running in this session. Stop-InteractiveTranscript works inside a session started by Start-InteractiveTranscript.'
        }

        if (Test-Path -LiteralPath $stopFilePath) {
            Write-Verbose -Message 'A stop request is already pending for the active recording.'
            return
        }

        if ($PSCmdlet.ShouldProcess('interactive transcript', 'Stop recording')) {
            Set-Content -LiteralPath $stopFilePath -Value 'stop'
            Write-Verbose -Message ("Stop request written to '{0}'; the recording will finalize momentarily." -f $stopFilePath)
        }
    }
}
