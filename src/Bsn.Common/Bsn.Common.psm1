#Requires -Version 5.1
<#
    Module loader for Bsn.Common.

    Defines the shared BsnOperatingSystem enum and Get-BsnOperatingSystem in
    this single file on purpose: PowerShell keyword-defined types (enum/class)
    are only resolvable as bare names within the compilation unit that defines
    them. Consumers must import this module and, when they need the type in a
    separately compiled file, add `using module Bsn.Common` at the top of that
    file. Never place a bare [BsnOperatingSystem] literal inside an attribute
    (e.g. [OutputType([BsnOperatingSystem])]) in a dot-sourced file - attribute
    binding happens at compile time and cannot resolve dynamic enums.
#>

Set-StrictMode -Version 'Latest'

enum BsnOperatingSystem {
    Windows
    Linux
    macOS
    Unknown
}

<#
.SYNOPSIS
    Detects the operating system PowerShell is running on.

.DESCRIPTION
    Uses the native .NET platform API
    ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform,
    available in .NET Core and .NET Framework 4.7.1+, which Windows 10 1809+
    ships with) and falls back to $env:OS on older Windows PowerShell hosts.

.OUTPUTS
    BsnOperatingSystem
        One of Windows, Linux, macOS or Unknown.
#>
function Get-BsnOperatingSystem {
    [CmdletBinding()]
    [OutputType('BsnOperatingSystem')]
    param()

    try {
        if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
            return [BsnOperatingSystem]::Windows
        }

        if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)) {
            return [BsnOperatingSystem]::Linux
        }

        if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
            return [BsnOperatingSystem]::macOS
        }

        return [BsnOperatingSystem]::Unknown
    }
    catch {
        # Windows PowerShell on .NET Framework < 4.7.1 lacks RuntimeInformation;
        # $env:OS is only defined on Windows.
        if ($env:OS -eq 'Windows_NT') {
            return [BsnOperatingSystem]::Windows
        }

        return [BsnOperatingSystem]::Unknown
    }
}
