@{
    RootModule = 'Bsn.Host.psm1'
    ModuleVersion = '0.2.2'
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
            ReleaseNotes = 'Bug fix release: recordings of byte-writing TUI applications (OpenCode and other Go/Node TUIs) are no longer corrupted to codepage mojibake - the recorded session bootstraps the console codepage to UTF-8; interop assembly loading is loader-managed (Import-Module -Force reuses the loaded assembly; cross-version imports get clear guidance and a session restart is required to switch versions). Also includes the 0.2.1 fixes: multi-byte UTF-8 survives chunk boundaries; cast files stay valid when the recording process dies; -Command values round-trip safely through pwsh -EncodedCommand; recording with both stdin and stdout redirected is a terminating error. Fixes issues #5, #6, #7, #8 and #15.'
        }
    }
}
