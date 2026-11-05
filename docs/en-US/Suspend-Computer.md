# Suspend-Computer

Puts one or more computers into a low-power state (sleep or hibernate).

`Suspend-Computer` completes the `*-Computer` power lifecycle family
(`Stop-Computer`, `Restart-Computer`) with the missing suspend state. It was
proposed to the PowerShell team in
[PowerShell#28164](https://github.com/PowerShell/PowerShell/issues/28164);
the Cmdlets Working Group recommended delivering it as a community module on
the PowerShell Gallery, which is exactly what `Bsn.SystemManagement` is.

## Syntax

```powershell
Suspend-Computer [[-ComputerName] <string[]>] [-Hibernate] [-Force]
                 [-WhatIf] [-Confirm]
```

## Platform support

| Platform | Sleep                          | Hibernate                              |
| -------- | ------------------------------ | -------------------------------------- |
| Windows  | `SetSuspendState` (powrprof.dll P/Invoke) | `SetSuspendState(hibernate: true)` |
| Linux    | `systemctl suspend` (`loginctl` fallback) | `systemctl hibernate` (requires the `disk` state in `/sys/power/state`) |
| macOS    | `pmset sleepnow`               | Not supported                          |

## Parameters

- **ComputerName** - target computers, defaulting to the local computer.
  Accepts pipeline input. Remote computers require PowerShell remoting
  (WinRM or SSH); the module does not need to be installed remotely.
- **Hibernate** - hibernate (S4) instead of sleep (S3 / Modern Standby).
- **Force** - skip the confirmation prompt and request a forced
  (critical) suspend.

## Examples

```powershell
Suspend-Computer -WhatIf
```

Shows what would happen without suspending anything.

```powershell
Suspend-Computer
```

Prompts for confirmation, then puts the local computer to sleep.

```powershell
Suspend-Computer -Hibernate -Force
```

Hibernates the local computer immediately, without a confirmation prompt.

```powershell
'WORKSTATION-07', 'WORKSTATION-12' | Suspend-Computer -Confirm:$false
```

Suspends two remote computers over PowerShell remoting without a prompt.

## Notes

The Windows implementation calls the documented
[`SetSuspendState`](https://learn.microsoft.com/en-us/windows/win32/api/powrprof/nf-powrprof-setsuspendstate)
API directly, avoiding both the undocumented
`rundll32.exe powrprof.dll,SetSuspendState` hack and loading WinForms.
