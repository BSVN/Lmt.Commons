# Bsn PowerShell modules

**ITNOA**

Online help for the **Bsn.\*** PowerShell module family published to the
[PowerShell Gallery](https://www.powershellgallery.com/) from the
[BSVN/Lmt.Commons](https://github.com/BSVN/Lmt.Commons) repository - one
repo, many independently-versioned modules, azure-powershell style.

The pages here are the same Markdown artifacts that ship inside each
module as PowerShell help: running `Get-Help <cmdlet>` locally shows the
same content. This site just makes it browsable without installing
anything. Docs track the repository `main` branch, so they can describe
changes that are not yet on the gallery.

## Modules

| Module | Description | Cmdlet reference |
|---|---|---|
| [Bsn.Common](en-US/about_Bsn.Common.md) | Shared helpers for the family | [Get-BsnOperatingSystem](en-US/Get-BsnOperatingSystem.md) |
| [Bsn.Host](en-US/about_Bsn.Host.md) | Terminal session recording, including full-screen TUI apps (asciicast v2/v3, optional GIF/WebM/MP4 render) | [Start-InteractiveTranscript](en-US/Start-InteractiveTranscript.md), [Stop-InteractiveTranscript](en-US/Stop-InteractiveTranscript.md), [Show-InteractiveTranscript](en-US/Show-InteractiveTranscript.md) |
| [Bsn.SystemManagement](en-US/about_Bsn.SystemManagement.md) | Basic system management that PowerShell ships without | [Suspend-Computer](en-US/Suspend-Computer.md) |

## Install

```powershell
Install-Module -Name Bsn.SystemManagement -Scope CurrentUser
Install-Module -Name Bsn.Host -Scope CurrentUser
```

`Bsn.Common` installs automatically as a dependency of the other modules.

## Quick start

```powershell
# Sleep or hibernate a machine - locally or over PowerShell remoting
Suspend-Computer -WhatIf
Suspend-Computer -Hibernate -Force
'PC-07', 'PC-12' | Suspend-Computer -Confirm:$false

# Record an interactive session - including TUI apps like vim or htop
Start-InteractiveTranscript          # enter the recorded session, 'exit' to stop
Start-InteractiveTranscript -Command 'nmtui' -Path .\demo.cast

# Play a recording back in the console (or: asciinema play .\demo.cast)
Show-InteractiveTranscript .\demo.cast -Speed 4 -IdleTimeLimit 2
```

## Contribute

- Source and issue tracker: [BSVN/Lmt.Commons](https://github.com/BSVN/Lmt.Commons)
- Contributing guide: [CONTRIBUTING.md](https://github.com/BSVN/Lmt.Commons/blob/main/CONTRIBUTING.md)
- License: [GPL-3.0](https://github.com/BSVN/Lmt.Commons/blob/main/LICENSE)
