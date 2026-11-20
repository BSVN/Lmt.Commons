# about_Bsn.SystemManagement

## Short description

Cross-platform system management cmdlets that fill the gaps left by the
built-in PowerShell modules.

## Long description

The `Bsn.SystemManagement` module provides cmdlets for basic system
management tasks that PowerShell ships without. It is part of the BSN
family of modules maintained in the
[BSVN/Lmt.Commons](https://github.com/BSVN/Lmt.Commons) repository.

The first cmdlet, [Suspend-Computer](Suspend-Computer.md), puts a
computer into a low-power state (sleep or hibernate) on Windows, Linux
and macOS. The request was proposed to the PowerShell team in
[PowerShell#28164](https://github.com/PowerShell/PowerShell/issues/28164)
and, following the recommendation of the PowerShell Cmdlets Working
Group, is delivered as a community module instead of a built-in cmdlet:

```powershell
Install-Module -Name Bsn.SystemManagement
```

## Platform support

| Platform | Sleep | Hibernate |
|---|---|---|
| Windows | `SetSuspendState` (powrprof.dll) | `SetSuspendState(hibernate: true)` |
| Linux | `systemctl suspend` (`loginctl` fallback) | `systemctl hibernate` (requires the `disk` state in `/sys/power/state`) |
| macOS | `pmset sleepnow` | Not supported |

## Remote computers

[Suspend-Computer](Suspend-Computer.md) accepts remote computer names and
connects over PowerShell remoting (WinRM or SSH). The target must have
remoting enabled; the module itself does not need to be installed
remotely - the suspend action is shipped to the target as a
self-contained script.

## See also

- [Suspend-Computer](Suspend-Computer.md)
- [about_Bsn.Common](about_Bsn.Common.md)
- `Stop-Computer`, `Restart-Computer`
