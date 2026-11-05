# Private helper functions

Every `*.ps1` file in this folder is automatically dot-sourced by the module
loader (`<module>.psm1`) and is available to all public commands, but is not
exported from the module.

Naming convention: `<ApprovedVerb>-Bsn<Noun>`, for example
`Get-BsnOperatingSystem`.
