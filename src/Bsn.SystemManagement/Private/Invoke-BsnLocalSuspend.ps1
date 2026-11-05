<#
.SYNOPSIS
    Executes the self-contained suspend action script on the local computer.

.DESCRIPTION
    Delegates to scripts/Suspend-Action.ps1, which performs the actual
    platform-specific suspend. The same script file is shipped to remote
    computers by Suspend-Computer, keeping one implementation of the
    suspend logic.
#>
function Invoke-BsnLocalSuspend {
    [CmdletBinding()]
    param(
        [switch]$Hibernate,

        [switch]$Force
    )

    if (-not (Test-Path -LiteralPath $script:SuspendActionScriptPath)) {
        throw ("The suspend action script was not found at '{0}'." -f $script:SuspendActionScriptPath)
    }

    $null = & $script:SuspendActionScriptPath -Hibernate ([bool]$Hibernate.IsPresent) -Force ([bool]$Force.IsPresent)
}
