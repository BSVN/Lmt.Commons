<#
.SYNOPSIS
    Plays back an interactive transcript recording in the console.

.DESCRIPTION
    Replays an asciicast v2 (.cast) file - as recorded by
    Start-InteractiveTranscript or asciinema - in the current console,
    re-emitting the output stream ('o' events) with the original timing.
    This is the PowerShell-native equivalent of 'asciinema play', covering
    view scenarios directly inside PowerShell.

    Input ('i') events are not replayed; resize ('r') events are ignored
    (the current console keeps its own size).

    On Windows the console output encoding is temporarily switched to
    UTF-8 for the playback and restored afterwards: Windows PowerShell
    5.1 hosts write [Console] output through the console output codepage,
    which would otherwise render characters outside CP437 (e.g. heavy
    box-drawing borders) as literal '?'.

.PARAMETER Path
    The asciicast v2 (.cast) file to play back.

.PARAMETER IdleTimeLimit
    When greater than zero (seconds), pauses longer than this limit are
    shortened to it, mirroring asciinema's --idle-time-limit behaviour.
    Zero (default) preserves original timing.

.PARAMETER Speed
    Playback speed multiplier (1 = original speed). Accepts values from
    0.1 (ten times slower) to 100 (one hundred times faster).

.INPUTS
    System.String
        The cast file path from the pipeline.

.OUTPUTS
    None

.EXAMPLE
    Show-InteractiveTranscript -Path .\audit\session01.cast

    Replays the recording at original speed.

.EXAMPLE
    Show-InteractiveTranscript -Path .\audit\session01.cast -Speed 4 -IdleTimeLimit 2

    Replays four times faster, skipping pauses longer than two seconds.
#>
function Show-InteractiveTranscript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [string]$Path,

        [ValidateRange(0, [double]::MaxValue)]
        [double]$IdleTimeLimit = 0,

        [ValidateRange(0.1, 100)]
        [double]$Speed = 1
    )

    process {
        $timeline = Get-BsnCastTimeline -Path $Path

        # Windows PowerShell 5.1 (.NET Framework) writes [Console] output
        # through the console OUTPUT CODEPAGE (WriteFile), so playback
        # characters outside that codepage - e.g. OpenCode's heavy
        # box-drawing border U+2503 on an OEM-codepage (437) console - are
        # replaced with literal '?' before rendering, while ASCII and CP437
        # blocks survive (the recorded cast itself is lossless UTF-8; pwsh 7
        # writes via WriteConsoleW and is unaffected). Switch the console
        # output encoding to UTF-8 for the duration of the playback and
        # restore the original afterwards - the same restore discipline the
        # recording engine uses for the live proxy view (issue #5).
        $previousOutputEncoding = [Console]::OutputEncoding
        $changedOutputEncoding = $false
        if ($previousOutputEncoding.CodePage -ne 65001) {
            try {
                [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
                $changedOutputEncoding = $true
            }
            catch {
                # No attached console or a host that refuses the switch (some
                # IDE/redirected setups): playback continues with the current
                # encoding, which is what previous versions did.
                Write-Verbose -Message ('Could not switch the console output encoding to UTF-8 for playback: ' + $_.Exception.Message)
            }
        }

        try {
            $previousTime = 0.0
            foreach ($timelineEvent in $timeline.Events) {
                $eventTime = [double]$timelineEvent[0]
                $delaySeconds = $eventTime - $previousTime
                if (($IdleTimeLimit -gt 0) -and ($delaySeconds -gt $IdleTimeLimit)) {
                    $delaySeconds = $IdleTimeLimit
                }
                $delaySeconds = $delaySeconds / $Speed

                if ($delaySeconds -gt 0) {
                    Start-Sleep -Milliseconds ([int]($delaySeconds * 1000))
                }

                $eventType = [string]$timelineEvent[1]
                if ($eventType -eq 'o') {
                    [Console]::Write([string]$timelineEvent[2])
                }

                $previousTime = $eventTime
            }
        }
        finally {
            if ($changedOutputEncoding) {
                try {
                    [Console]::OutputEncoding = $previousOutputEncoding
                }
                catch {
                    Write-Verbose -Message ('Could not restore the console output encoding: ' + $_.Exception.Message)
                }
            }
        }
    }
}
