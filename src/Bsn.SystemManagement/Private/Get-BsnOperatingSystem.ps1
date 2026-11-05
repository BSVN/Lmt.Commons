<#
.SYNOPSIS
    Detects the operating system the module is running on.

.DESCRIPTION
    Returns one of 'Windows', 'Linux', 'macOS' or 'Unknown'. Works on
    PowerShell 7+ (where $PSVersionTable.Platform is defined) and on
    Windows PowerShell 5.1 (where it falls back to $env:OS).
#>
function Get-BsnOperatingSystem {
    [CmdletBinding()]
    [OutputType([string])]
    param()

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
