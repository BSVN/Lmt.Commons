using module Bsn.Common

<#
.SYNOPSIS
    Suspends (sleeps or hibernates) the local computer.

.DESCRIPTION
    On Windows, calls the documented SetSuspendState API through the compiled
    Bsn.SystemManagement interop assembly (lib/Bsn.SystemManagement.dll,
    loaded via the module manifest). On Linux/macOS, delegates to the
    self-contained scripts/Suspend-Action.ps1, which drives systemctl/loginctl
    or pmset. The same action script is also shipped to remote computers by
    Suspend-Computer (Invoke-Command -FilePath); its inline P/Invoke copy of
    the API is intentionally kept because a single .ps1 file is the only
    payload remoting can deliver.
#>
function Invoke-BsnLocalSuspend {
    [CmdletBinding()]
    param(
        [switch]$Hibernate,

        [switch]$Force,

        [int]$After = 0
    )

    # Grace period for the '-After' delay (issue #17): the countdown runs on
    # the target machine, and Ctrl+C during the sleep cancels the pending
    # suspension because the pipeline stops before the suspend call.
    if ($After -gt 0) {
        Write-Warning -Message ("Suspending in {0} seconds; press Ctrl+C to cancel." -f $After)
        Start-Sleep -Seconds $After
    }

    if ((Get-BsnOperatingSystem) -eq [BsnOperatingSystem]::Windows) {
        $succeeded = [Bsn.SystemManagement.Interop.PowerProf]::SetSuspendState([bool]$Hibernate.IsPresent, [bool]$Force.IsPresent, $false)
        if (-not $succeeded) {
            $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw ("SetSuspendState failed with Win32 error code {0}." -f $errorCode)
        }
        return
    }

    if (-not (Test-Path -LiteralPath $script:SuspendActionScriptPath)) {
        throw ("The suspend action script was not found at '{0}'." -f $script:SuspendActionScriptPath)
    }

    $null = & $script:SuspendActionScriptPath -Hibernate ([bool]$Hibernate.IsPresent) -Force ([bool]$Force.IsPresent)
}
