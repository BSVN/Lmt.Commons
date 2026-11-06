@{
    RootModule = 'Bsn.SystemManagement.psm1'
    ModuleVersion = '0.2.0'
    GUID = 'b7d64e3a-2f4e-4f8a-9a1d-3c5e7a9b1f02'
    Author = 'BSVN'
    CompanyName = 'BSVN'
    Copyright = '(c) 2026 BSVN. All rights reserved.'
    Description = 'Cross-platform system management cmdlets that fill the gaps left by the built-in PowerShell modules, starting with Suspend-Computer (sleep/hibernate) as requested in https://github.com/PowerShell/PowerShell/issues/28164.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    RequiredModules = @(
        @{ ModuleName = 'Bsn.Common'; ModuleVersion = '0.1.0' }
    )
    RequiredAssemblies = @('lib/Bsn.SystemManagement.dll')
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
            ReleaseNotes = 'Suspend-Computer now uses the compiled Bsn.SystemManagement interop assembly locally (self-contained action script remains for remoting) and depends on the shared Bsn.Common module. See https://github.com/BSVN/Lmt.Commons/blob/main/CHANGELOG.md.'
        }
    }
}
