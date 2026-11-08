<#
.SYNOPSIS
    Suspends (sleeps or hibernates) the local computer.

.DESCRIPTION
    Self-contained suspend implementation for Bsn.SystemManagement. It is
    executed directly on the local computer and shipped as-is to remote
    computers by Suspend-Computer via Invoke-Command -FilePath, so it must
    not depend on any other module file.

    Platform implementation:
    - Windows: P/Invoke of the documented SetSuspendState API in powrprof.dll.
    - Linux:   systemctl suspend/hibernate, loginctl as fallback.
    - macOS:   pmset sleepnow (hibernate is not supported).

.NOTES
    Part of Bsn.SystemManagement - do not dot-source from the module loader.
#>
[CmdletBinding()]
param(
    [bool]$Hibernate,

    [bool]$Force,

    [int]$After = 0
)

$ErrorActionPreference = 'Stop'

# Grace period for the '-After' delay (issue #17): the countdown runs on the
# target machine, and Ctrl+C during the sleep cancels the pending suspension.
if ($After -gt 0) {
    Write-Warning -Message ("Suspending in {0} seconds; press Ctrl+C to cancel." -f $After)
    Start-Sleep -Seconds $After
}

function Get-TargetPlatform {
    # PSVersionTable keys 'Platform' and 'OS' do not exist on Windows
    # PowerShell 5.1 - guard with ContainsKey to stay StrictMode-safe.
    $hasPlatformKey = $PSVersionTable.ContainsKey('Platform')

    if ($hasPlatformKey -and ($PSVersionTable['Platform'] -eq 'Win32NT')) {
        return 'Windows'
    }

    if ($hasPlatformKey -and ($PSVersionTable['Platform'] -eq 'Unix')) {
        if ($PSVersionTable.ContainsKey('OS') -and ($PSVersionTable['OS'] -match 'Darwin')) {
            return 'macOS'
        }
        return 'Linux'
    }

    # Windows PowerShell 5.1 does not define $PSVersionTable.Platform.
    if ($env:OS -eq 'Windows_NT') {
        return 'Windows'
    }

    return 'Unknown'
}

$platform = Get-TargetPlatform

switch ($platform) {
    'Windows' {
        if (-not ('Bsn.SystemManagement.Interop.PowerProf' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Bsn.SystemManagement.Interop
{
    /// <summary>P/Invoke wrapper for the documented Windows power APIs.</summary>
    public static class PowerProf
    {
        [DllImport("powrprof.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent);
    }
}
'@
        }

        $succeeded = [Bsn.SystemManagement.Interop.PowerProf]::SetSuspendState($Hibernate, $Force, $false)
        if (-not $succeeded) {
            $errorCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw ("SetSuspendState failed with Win32 error code {0}." -f $errorCode)
        }
    }

    'Linux' {
        $action = if ($Hibernate) { 'hibernate' } else { 'suspend' }

        if ($Hibernate) {
            $powerStates = Get-Content -LiteralPath '/sys/power/state' -ErrorAction 'SilentlyContinue'
            if (-not ($powerStates -match 'disk')) {
                throw 'Hibernate was requested but this Linux system does not expose the "disk" power state (hibernation is not available).'
            }
        }

        foreach ($controller in @('systemctl', 'loginctl')) {
            $controllerCommand = Get-Command -Name $controller -ErrorAction 'SilentlyContinue'
            if (-not $controllerCommand) {
                continue
            }

            & $controllerCommand.Source $action
            if ($LASTEXITCODE -ne 0) {
                throw ("{0} {1} failed with exit code {2}." -f $controller, $action, $LASTEXITCODE)
            }
            return
        }

        throw 'No supported suspend mechanism was found (expected systemctl or loginctl).'
    }

    'macOS' {
        if ($Hibernate) {
            throw 'Hibernate is not supported by Suspend-Computer on macOS; use sleep instead.'
        }

        & pmset sleepnow
        if ($LASTEXITCODE -ne 0) {
            throw ("pmset sleepnow failed with exit code {0}." -f $LASTEXITCODE)
        }
    }

    default {
        throw ("Suspend is not supported on this platform ('{0}')." -f $platform)
    }
}
