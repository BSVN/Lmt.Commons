@{
    RootModule = 'Bsn.Host.psm1'
    ModuleVersion = '0.2.4'
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
            ReleaseNotes = 'Bug fix release: recordings on Linux distros shipping util-linux 2.39 or 2.41 (Ubuntu 24.04 and 26.04) came back empty - the script(1) invocation combined --log-out with a trailing positional file, rejected since util-linux 2.39; the engine now probes the installed script(1) binary and picks the invocation shape it accepts, and a CI-runnable Linux/macOS script(1) engine system test plus a pinned ubuntu-24.04 CI image pin the regression. Also includes the 0.2.3 fixes: the LIVE recording view and Show-InteractiveTranscript playback no longer corrupt box-drawing characters on OEM-codepage consoles - the console output codepage/encoding is switched to UTF-8 for the operation and restored afterwards. Fixes issue #5.'
        }
    }
}
