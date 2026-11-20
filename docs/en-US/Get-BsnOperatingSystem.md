# Get-BsnOperatingSystem

Detects the operating system PowerShell is running on.

`Get-BsnOperatingSystem` is the shared OS-detection helper of the
`Bsn.*` module family (module `Bsn.Common`). It returns the native
`BsnOperatingSystem` enum, so cmdlets can branch on platform without
duplicating detection logic. `Bsn.Host` and `Bsn.SystemManagement` use it
to pick their engines: ConPTY vs `script(1)` for recording,
`SetSuspendState` vs `systemctl` vs `pmset` for suspending.

## Syntax

```powershell
Get-BsnOperatingSystem
```

## Outputs

`BsnOperatingSystem` - one of:

| Value | Detection |
|---|---|
| `Windows` | `RuntimeInformation.IsOSPlatform(OSPlatform.Windows)` |
| `Linux` | `RuntimeInformation.IsOSPlatform(OSPlatform.Linux)` |
| `macOS` | `RuntimeInformation.IsOSPlatform(OSPlatform.OSX)` |
| `Unknown` | nothing matched, or detection is unavailable on a non-Windows host |

## Examples

```powershell
Get-BsnOperatingSystem
```

On a Windows machine this returns `Windows`; on Linux `Linux`; on macOS
`macOS`.

```powershell
switch (Get-BsnOperatingSystem) {
    'Windows' { '.\setup-windows.ps1' }
    'Linux'   { './setup-linux.sh' }
    'macOS'   { './setup-macos.sh' }
    default   { throw 'Unsupported platform.' }
}
```

Branches a setup script on the detected platform.

## Notes

- Detection uses the native .NET API
  `System.Runtime.InteropServices.RuntimeInformation.IsOSPlatform`
  (available on .NET Core / .NET 5+ and .NET Framework 4.7.1+, which
  Windows 10 1809+ ships with) and falls back to the `$env:OS` variable
  on older Windows PowerShell hosts, where that API is missing.
- Prefer it over reading `$PSVersionTable.Platform` directly: that key
  does not exist on Windows PowerShell 5.1, where accessing it under
  `Set-StrictMode -Version Latest` throws a
  `PropertyNotFoundException`.

## See also

- [about_Bsn.Common](about_Bsn.Common.md)
- [Suspend-Computer](Suspend-Computer.md)
- [Start-InteractiveTranscript](Start-InteractiveTranscript.md)
