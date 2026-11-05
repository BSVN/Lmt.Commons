@{
    RootModule = 'Bsn.Common.psm1'
    ModuleVersion = '0.1.0'
    GUID = '4a2f0a3f-6d21-4c7e-9f42-8b3d1e5c9a76'
    Author = 'BSVN'
    CompanyName = 'BSVN'
    Copyright = '(c) 2026 BSVN. All rights reserved.'
    Description = 'Shared internal helpers for the Bsn.* module family: operating system detection and common types.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport = @('Get-BsnOperatingSystem')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    DscResourcesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('BSVN', 'Lmt')
            LicenseUri = 'https://github.com/BSVN/Lmt.Commons/blob/main/LICENSE'
            ProjectUri = 'https://github.com/BSVN/Lmt.Commons'
            ReleaseNotes = 'Initial release: Get-BsnOperatingSystem with the BsnOperatingSystem enum.'
        }
    }
}
