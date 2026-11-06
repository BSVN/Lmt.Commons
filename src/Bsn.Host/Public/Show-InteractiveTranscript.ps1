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
}
