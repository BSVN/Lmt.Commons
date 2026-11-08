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
            ReleaseNotes = 'Bug fix release (unreleased pending intentional release): TUI recordings no longer leave garbage like [4;600;1200t typed at the prompt after playback - the recorder filters response-eliciting terminal query sequences (XTWINOPS pixel-size, DSR, DA, kitty keyboard, OSC color queries) out of the cast at capture time (issue #20); recordings on Linux distros shipping util-linux 2.39+ (Ubuntu 24.04/26.04) work again via script(1) invocation probing; plus the 0.2.1-0.2.3 fixes: UTF-8 chunk-boundary corruption, live-view/playback codepage handling, incremental flush, pwsh -EncodedCommand wrapping, redirected-stdio detection and loader-managed interop assemblies. Fixes issues #5, #6, #7, #8, #20.'
        }
    }
}
