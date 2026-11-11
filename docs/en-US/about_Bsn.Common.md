# about_Bsn.Common

## Short description

Shared internal helpers for the `Bsn.*` module family.

## Long description

`Bsn.Common` factors the helpers that every `Bsn.*` module needs so they
are implemented exactly once. It currently provides:

- [Get-BsnOperatingSystem](Get-BsnOperatingSystem.md): returns the
  `BsnOperatingSystem` enum value (`Windows`, `Linux`, `macOS`,
  `Unknown`) using the native .NET platform detection API.

Modules in the [BSVN/Lmt.Commons](https://github.com/BSVN/Lmt.Commons)
repository declare `Bsn.Common` in `RequiredModules` and import it in
their module loader. It is published to the PowerShell Gallery so the
dependency resolves for end users:

```powershell
Install-Module -Name Bsn.Common
```

The module is not a user-facing toolbox; it exists so consumer modules
(`Bsn.Host`, `Bsn.SystemManagement`, and future `Bsn.*` modules) share
one tested implementation instead of duplicated copies.

## Using the BsnOperatingSystem enum

The enum is a native PowerShell enum defined in `Bsn.Common.psm1`. Code
in other modules can use bare `[BsnOperatingSystem]` literals in function
bodies and parameter type constraints once this module is loaded. Never
place the literal inside an attribute - use the string form
`[OutputType('BsnOperatingSystem')]` instead, because attribute binding
happens at compile time and cannot resolve dynamic enums.

## See also

- [Get-BsnOperatingSystem](Get-BsnOperatingSystem.md)
- [about_Bsn.Host](about_Bsn.Host.md)
- [about_Bsn.SystemManagement](about_Bsn.SystemManagement.md)
