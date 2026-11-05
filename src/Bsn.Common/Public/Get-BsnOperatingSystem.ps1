<#
.SYNOPSIS
    Detects the operating system PowerShell is running on.

.DESCRIPTION
    Uses the native .NET platform API
    ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform,
    available in .NET Core and .NET Framework 4.7.1+, which Windows 10 1809+
    ships with) and falls back to $env:OS on older Windows PowerShell hosts.

.OUTPUTS
    Bsn.Common.BsnOperatingSystem
        One of Windows, Linux, macOS or Unknown.
#>
function Get-BsnOperatingSystem {
    [CmdletBinding()]
    [OutputType('Bsn.Common.BsnOperatingSystem')]
    param()

    try {
        if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
            return [Bsn.Common.BsnOperatingSystem]::Windows
        }

        if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)) {
            return [Bsn.Common.BsnOperatingSystem]::Linux
        }

        if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
            return [Bsn.Common.BsnOperatingSystem]::macOS
        }

        return [Bsn.Common.BsnOperatingSystem]::Unknown
    }
    catch {
        # Windows PowerShell on .NET Framework < 4.7.1 lacks RuntimeInformation;
        # $env:OS is only defined on Windows.
        if ($env:OS -eq 'Windows_NT') {
            return [Bsn.Common.BsnOperatingSystem]::Windows
        }

        return [Bsn.Common.BsnOperatingSystem]::Unknown
    }
}
