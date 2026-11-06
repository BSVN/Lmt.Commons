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

<#
.SYNOPSIS
    Loads a module interop assembly with same-session reimport tolerance.

.DESCRIPTION
    PowerShell's assembly loading dedupes by simple assembly name, so a
    module that ships its DLL through RequiredAssemblies (or plain
    Add-Type) cannot be re-imported from a different installed version in
    the same session: the second load fails with FileLoadException
    ("Assembly with same name is already loaded").

    The Bsn.* modules load their interop assemblies through this helper
    instead of RequiredAssemblies:
    - when an assembly with the same name AND version is already loaded
      (Import-Module -Force of the same version), it is reused silently;
    - when a DIFFERENT version is already loaded (Import-Module after
      Update-Module), it fails with actionable guidance, because
      PowerShell cannot host two versions of the same assembly in one
      process - this is why the interop assemblies are stamped with the
      module version at build time (build.ps1 passes -p:Version from the
      manifest; guard tests assert the equality);
    - otherwise the assembly is loaded from the given path.

    https://github.com/BSVN/Lmt.Commons/issues/15

    Kept private (consumer module loaders invoke it through this module's
    scope) so it does not extend Bsn.Common's public command surface.
#>
function Import-BsnInteropAssembly {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$AssemblyName
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw ("The interop assembly is missing at '{0}'. Run './build.ps1' to build it, or reinstall the module." -f $Path)
    }

    $fileVersion = [System.Reflection.AssemblyName]::GetAssemblyName($Path).Version
    $loadedAssemblies = @([System.AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -eq $AssemblyName })
    if ($loadedAssemblies.Count -gt 0) {
        $loadedVersion = $loadedAssemblies[0].GetName().Version
        if ($loadedVersion -ne $fileVersion) {
            throw ("Cannot load {0} version {1}: version {2} is already loaded in this session (from '{3}'). PowerShell cannot host two versions of the same assembly in one process; restart the session (or open a new one) and import the module again. https://github.com/BSVN/Lmt.Commons/issues/15" -f $AssemblyName, $fileVersion, $loadedVersion, $loadedAssemblies[0].Location)
        }

        # Same version already loaded (e.g. Import-Module -Force): reuse it.
        return
    }

    Add-Type -Path $Path
}
