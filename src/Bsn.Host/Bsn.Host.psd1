@{
    RootModule = 'Bsn.Host.psm1'
    ModuleVersion = '0.2.3'
    GUID = '9d84a7b8-1f2b-4d60-a4bd-3d7ef1d9f337'
    Author = 'BSVN'
    CompanyName = 'BSVN'
    Copyright = '(c) 2026 BSVN. All rights reserved.'
    Description = 'Interactive terminal session recording for PowerShell hosts: records commands - including full-screen TUI applications - to replayable asciicast v2 files, with in-console playback and optional video rendering.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    RequiredModules = @(
        @{ ModuleName = 'Bsn.Common'; ModuleVersion = '0.1.1' }
    )
    FunctionsToExport = @('Start-InteractiveTranscript', 'Stop-InteractiveTranscript', 'Show-InteractiveTranscript')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    DscResourcesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('BSVN', 'Lmt', 'Host', 'Transcript', 'Recording', 'Terminal', 'Session', 'Asciicast', 'Asciinema', 'TUI', 'Audit', 'Screencast')
            LicenseUri = 'https://github.com/BSVN/Lmt.Commons/blob/main/LICENSE'
            ProjectUri = 'https://github.com/BSVN/Lmt.Commons'
            ReleaseNotes = 'Bug fix release: the LIVE recording view (what you watch while recording) no longer turns box-drawing text into CP437 mojibake on OEM-codepage consoles (cmd, Windows PowerShell 5.1 hosts) - the engine switches the console to UTF-8 for the recording and restores it afterwards; the cast file was always correct. Also includes the 0.2.2 fixes: recordings of byte-writing TUI applications (OpenCode and other Go/Node TUIs) bootstrap the console codepage to UTF-8; interop assembly loading is loader-managed (Import-Module -Force reuses the loaded assembly; cross-version imports get clear guidance). Fixes issues #5 and #15.'
        }
    }
}
