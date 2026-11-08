<#
.SYNOPSIS
    Runs the grace period before a pending computer suspension.

.DESCRIPTION
    Implements the '-After' delay of Suspend-Computer (issue #17): warns
    that a suspension is pending and sleeps for the requested number of
    seconds. Ctrl+C during the sleep cancels the pipeline and with it the
    pending suspension.

    Extracted as its own function so the delay is unit testable (the
    suspend implementations themselves must never run inside tests).
#>
function Wait-BsnSuspendGracePeriod {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$Seconds
    )

    if ($Seconds -gt 0) {
        Write-Warning -Message ("Suspending in {0} seconds; press Ctrl+C to cancel." -f $Seconds)
        Start-Sleep -Seconds $Seconds
    }
}
