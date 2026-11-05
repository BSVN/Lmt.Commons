<#
.SYNOPSIS
    Detects the operating system the module is running on.

.DESCRIPTION
    Returns one of 'Windows', 'Linux', 'macOS' or 'Unknown'. Works on
    PowerShell 7+ and on Windows PowerShell 5.1 (guarded hashtable lookups
    because $PSVersionTable.Platform does not exist there).

.NOTES
    Intentionally duplicated from Bsn.SystemManagement: modules in this
    repository stay self-contained and do not import each other for a
    30-line helper.
#>
function Get-BsnOperatingSystem {
    [CmdletBinding()]
    [OutputType([string])]
    param()

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

    if ($env:OS -eq 'Windows_NT') {
        return 'Windows'
    }

    return 'Unknown'
}
