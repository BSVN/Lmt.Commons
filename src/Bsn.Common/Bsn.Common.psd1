@{
    RootModule = 'Bsn.Common.psm1'
    ModuleVersion = '0.1.1'
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
            ReleaseNotes = 'Adds the private Import-BsnInteropAssembly helper used by the Bsn.* module loaders: reuses an already-loaded same-version interop assembly on Import-Module -Force, and fails with actionable guidance when a different version is already in the session (issue #15).'
        }
    }
}
