@{
    RootModule = 'Bsn.SystemManagement.psm1'
    ModuleVersion = '0.2.1'
    GUID = 'b7d64e3a-2f4e-4f8a-9a1d-3c5e7a9b1f02'
    Author = 'BSVN'
    CompanyName = 'BSVN'
    Copyright = '(c) 2026 BSVN. All rights reserved.'
    Description = 'Cross-platform system management cmdlets that fill the gaps left by the built-in PowerShell modules, starting with Suspend-Computer (sleep/hibernate) as requested in https://github.com/PowerShell/PowerShell/issues/28164.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    RequiredModules = @(
        @{ ModuleName = 'Bsn.Common'; ModuleVersion = '0.1.1' }
    )
    FunctionsToExport = @('Suspend-Computer')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    DscResourcesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('System', 'Management', 'Power', 'Sleep', 'Hibernate', 'Suspend', 'CrossPlatform', 'Windows', 'Linux', 'macOS', 'BSVN', 'Lmt')
            LicenseUri = 'https://github.com/BSVN/Lmt.Commons/blob/main/LICENSE'
            ProjectUri = 'https://github.com/BSVN/Lmt.Commons'
            ReleaseNotes = 'Interop assembly loading is now managed by the module loader (via Bsn.Common 0.1.1): re-importing with Import-Module -Force reuses the already-loaded assembly, and importing after Update-Module fails with clear guidance instead of a raw FileLoadException (a session restart is still required to switch assembly versions). The interop assembly now carries the module version as its assembly version. Suspend-Computer behavior is unchanged. See https://github.com/BSVN/Lmt.Commons/blob/main/CHANGELOG.md and issue #15.'
        }
    }
}
