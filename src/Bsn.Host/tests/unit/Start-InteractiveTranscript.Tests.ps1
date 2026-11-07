[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingComputerNameHardcoded', '', Justification = 'Not applicable - no computer names in this file.')]
param()

BeforeAll {
    $moduleRoot = Split-Path -Parent -Path (Split-Path -Parent -Path $PSScriptRoot)
    $manifestPath = Join-Path -Path $moduleRoot -ChildPath 'Bsn.Host.psd1'
    # The module's DLL may already be loaded in this process (e.g., by PSScriptAnalyzer
    # analyzing the manifest), which makes Import-Module fail with FileLoadException.
    # Fall back to importing the psm1 directly - the assembly is already in memory.
    try {
        Import-Module -Name $manifestPath -Force -ErrorAction 'Stop'
    }
    catch [System.IO.FileLoadException] {
        Import-Module -Name (Join-Path $moduleRoot 'Bsn.Host.psm1') -Force -ErrorAction 'Stop'
    }

    # Native keyword enums cannot be referenced by a bare type literal from
    # test scope: the literal resolves only in files whose 'using module'
    # header bound it at compile time (module files; see AGENTS.md), and a
    # using header in this test file would execute before BeforeAll can make
    # Bsn.Common resolvable. Pull the enum value from the defining module's
    # own scope instead, where the literal always resolves.
    $script:BsnWindows = & (Get-Module -Name 'Bsn.Common') { [BsnOperatingSystem]::Windows }
}

Describe 'Start-InteractiveTranscript' {
    Context 'parameter set' {
        It 'supports WhatIf and Confirm' {
            $command = Get-Command -Name 'Start-InteractiveTranscript'
            $command.Parameters.ContainsKey('WhatIf') | Should -BeTrue
            $command.Parameters.ContainsKey('Confirm') | Should -BeTrue
        }

        It 'accepts the command as a positional parameter' {
            (Get-Command -Name 'Start-InteractiveTranscript').Parameters['Command'].ParameterType | Should -Be ([string])
        }
    }

    Context 'path handling' {
        BeforeEach {
            Mock -CommandName Test-BsnRecordingEnvironment -ModuleName 'Bsn.Host' { }
            Mock -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' {
                [pscustomobject]@{ ExitCode = 0; DurationSec = 1.5; StoppedByRequest = $false; Completed = $true }
            }
            Mock -CommandName Start-BsnUnixPtyRecording -ModuleName 'Bsn.Host' {
                [pscustomobject]@{ ExitCode = 0; DurationSec = 1.5; StoppedByRequest = $false; Completed = $true }
            }
            Mock -CommandName Get-BsnOperatingSystem -ModuleName 'Bsn.Host' { 'Windows' }
        }

        It 'rejects an existing cast file without -Force' {
            $existingPath = Join-Path -Path $TestDrive -ChildPath 'session.cast'
            Set-Content -LiteralPath $existingPath -Value 'existing'
            { Start-InteractiveTranscript -Path $existingPath -ErrorAction 'Stop' } | Should -Throw
        }

        It 'overwrites an existing cast file with -Force' {
            $existingPath = Join-Path -Path $TestDrive -ChildPath 'session.cast'
            Set-Content -LiteralPath $existingPath -Value 'existing'
            Start-InteractiveTranscript -Path $existingPath -Force
            Should -Invoke -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' -Times 1 -Exactly -Scope It
        }

        It 'rejects paths in a non-existing directory' {
            $missingDirectory = Join-Path -Path $TestDrive -ChildPath 'missing'
            { Start-InteractiveTranscript -Path (Join-Path -Path $missingDirectory -ChildPath 'x.cast') -ErrorAction 'Stop' } | Should -Throw
        }
    }

    Context 'dispatching to platform engines' {
        BeforeEach {
            Mock -CommandName Test-BsnRecordingEnvironment -ModuleName 'Bsn.Host' { }
        }

        It 'routes Windows to the ConPTY engine with a wrapped command line' {
            Mock -CommandName Get-BsnOperatingSystem -ModuleName 'Bsn.Host' { 'Windows' }
            Mock -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' {
                [pscustomobject]@{ ExitCode = 7; DurationSec = 2.25; StoppedByRequest = $false; Completed = $true }
            }
            Mock -CommandName Start-BsnUnixPtyRecording -ModuleName 'Bsn.Host' { }

            $recording = Start-InteractiveTranscript -Command 'echo hi' -Path (Join-Path -Path $TestDrive -ChildPath 'a.cast')

            # Issue #7 fix: the engine now wraps -Command in pwsh -EncodedCommand
            # (Base64) instead of cmd.exe /d /c, which mangled metacharacters.
            # https://github.com/BSVN/Lmt.Commons/issues/7
            Should -Invoke -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' -Times 1 -Exactly -Scope It -ParameterFilter { $CommandLine -like '*-EncodedCommand*' }
            $recording.ExitCode | Should -Be 7
            $recording.DurationSec | Should -Be 2.25
        }

        It 'routes Linux to the script(1) engine' {
            Mock -CommandName Get-BsnOperatingSystem -ModuleName 'Bsn.Host' { 'Linux' }
            Mock -CommandName Start-BsnUnixPtyRecording -ModuleName 'Bsn.Host' {
                [pscustomobject]@{ ExitCode = 0; DurationSec = 1.0; StoppedByRequest = $false; Completed = $true }
            }
            Mock -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' { }

            Start-InteractiveTranscript -Command 'htop' -Path (Join-Path -Path $TestDrive -ChildPath 'b.cast')

            Should -Invoke -CommandName Start-BsnUnixPtyRecording -ModuleName 'Bsn.Host' -Times 1 -Exactly -Scope It -ParameterFilter { $Command -eq 'htop' }
        }

        It 'propagates the recorded exit code to LASTEXITCODE' {
            Mock -CommandName Get-BsnOperatingSystem -ModuleName 'Bsn.Host' { 'Windows' }
            Mock -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' {
                [pscustomobject]@{ ExitCode = 42; DurationSec = 1.0; StoppedByRequest = $false; Completed = $true }
            }

            Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'c.cast')
            $LASTEXITCODE | Should -Be 42
        }
    }

    Context 'recording options (RFC 421 semantics)' {
        BeforeEach {
            Mock -CommandName Test-BsnRecordingEnvironment -ModuleName 'Bsn.Host' { }
            Mock -CommandName Get-BsnOperatingSystem -ModuleName 'Bsn.Host' { 'Windows' }
            Mock -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' {
                [pscustomobject]@{ ExitCode = 0; DurationSec = 1.0; StoppedByRequest = $false; Completed = $true }
            }
            Mock -CommandName Start-BsnUnixPtyRecording -ModuleName 'Bsn.Host' { }
        }

        It 'writes asciicast v2 by default and v3 on request' {
            Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'v2default.cast')
            Should -Invoke -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' -Times 1 -Exactly -Scope It -ParameterFilter { $CastVersion -eq 2 }

            Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'v3.cast') -CastVersion 3
            Should -Invoke -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' -Times 1 -Exactly -Scope It -ParameterFilter { $CastVersion -eq 3 }
        }

        It 'threads the recording indicator into the nested shell command line' {
            Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'indicator.cast')
            Should -Invoke -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' -Times 1 -Exactly -Scope It -ParameterFilter { $CommandLine -notlike '*function prompt*' }

            Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'indicator2.cast') -ShowRecordingIndicator
            Should -Invoke -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' -Times 1 -Exactly -Scope It -ParameterFilter { ($CommandLine -like '*function prompt*') -and ($CommandLine -like '*0x23FA*') }
        }

        It 'warns when the indicator is combined with -Command' {
            Start-InteractiveTranscript -Command 'echo hi' -Path (Join-Path -Path $TestDrive -ChildPath 'indicator3.cast') -ShowRecordingIndicator -WarningVariable indicatorWarning
            ($indicatorWarning | Where-Object -FilterScript { $_ -like '*only to the interactive shell mode*' }) | Should -Not -BeNullOrEmpty
        }

        It 'does not render anything for the default Asciicast format' {
            Mock -CommandName Invoke-BsnCastRender -ModuleName 'Bsn.Host' { '/should/not/happen.gif' }

            $recording = Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'fmt.cast')

            Should -Invoke -CommandName Invoke-BsnCastRender -ModuleName 'Bsn.Host' -Times 0 -Exactly -Scope It
            $recording.VideoPath | Should -BeNullOrEmpty
        }

        It 'renders the requested video format after recording' {
            Mock -CommandName Invoke-BsnCastRender -ModuleName 'Bsn.Host' { '/recordings/demo.webm' }

            $recording = Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'fmt2.cast') -RecordingFormat 'WebM'

            Should -Invoke -CommandName Invoke-BsnCastRender -ModuleName 'Bsn.Host' -Times 1 -Exactly -Scope It -ParameterFilter { $Format -eq 'WebM' }
            $recording.VideoPath | Should -Be '/recordings/demo.webm'
        }

        It 'reports no video path when the renderer is unavailable' {
            Mock -CommandName Invoke-BsnCastRender -ModuleName 'Bsn.Host' { $null }

            $recording = Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'fmt3.cast') -RecordingFormat 'Gif'

            $recording.VideoPath | Should -BeNullOrEmpty
        }

        It 'applies the idle time limit after recording' {
            Mock -CommandName Optimize-BsnCastIdleTime -ModuleName 'Bsn.Host' { }

            Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'idle.cast') -RecordIdleTimeLimit 5

            Should -Invoke -CommandName Optimize-BsnCastIdleTime -ModuleName 'Bsn.Host' -Times 1 -Exactly -Scope It -ParameterFilter { $LimitSec -eq 5 }
        }

        It 'skips idle time processing for the default limit of zero' {
            Mock -CommandName Optimize-BsnCastIdleTime -ModuleName 'Bsn.Host' { }

            Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'idle2.cast')

            Should -Invoke -CommandName Optimize-BsnCastIdleTime -ModuleName 'Bsn.Host' -Times 0 -Exactly -Scope It
        }
    }

    Context 'rendering degradation (RFC 421 contract)' {
        It 'keeps the cast authoritative when the renderer is missing' {
            # 'agg' is not expected on CI images; when it genuinely is present this
            # test would fail - acceptable, since it proves the happy path instead.
            $aggCommand = Get-Command -Name 'agg' -ErrorAction 'SilentlyContinue'
            $castPath = Join-Path -Path $TestDrive -ChildPath 'degrade.cast'
            Set-Content -LiteralPath $castPath -Value '{"version": 2, "width": 80, "height": 24, "timestamp": 1793895000}'

            if ($aggCommand) {
                Set-ItResult -Skipped -Because 'agg is present on PATH, so the degradation path cannot be exercised.'
            }

            $renderResult = & (Get-Module -Name 'Bsn.Host') { param($p) Invoke-BsnCastRender -CastPath $p -Format 'Gif' } $castPath

            $renderResult | Should -BeNullOrEmpty
            (Test-Path -LiteralPath ([System.IO.Path]::ChangeExtension($castPath, 'gif'))) | Should -BeFalse
            (Get-Item -LiteralPath $castPath).Length | Should -BeGreaterThan 0
        }
    }

    Context 'environment constraint checks' {
        It 'runs the pre-flight checks before dispatching' {
            Mock -CommandName Test-BsnRecordingEnvironment -ModuleName 'Bsn.Host' { }
            Mock -CommandName Get-BsnOperatingSystem -ModuleName 'Bsn.Host' { 'Windows' }
            Mock -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' {
                [pscustomobject]@{ ExitCode = 0; DurationSec = 1.0; StoppedByRequest = $false; Completed = $true }
            }

            Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'env.cast')

            Should -Invoke -CommandName Test-BsnRecordingEnvironment -ModuleName 'Bsn.Host' -Times 1 -Exactly -Scope It
        }

        It 'rejects unknown platforms with an explicit message' {
            Mock -CommandName Get-BsnOperatingSystem -ModuleName 'Bsn.Host' { 'Unknown' }

            { Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'unknown.cast') -ErrorAction 'Stop' } | Should -Throw '*not supported on this platform*'
        }

        It 'throws when both stdin and stdout are redirected on Windows (issue #8)' {
            # https://github.com/BSVN/Lmt.Commons/issues/8
            # Requires a real Windows host: with -Platform Windows the version
            # guard runs before the redirected-stdio check, and on Unix hosts
            # [Environment]::OSVersion.Version is the kernel version (major
            # below 10), so the version error fires instead of the stdio one.
            # Compare against the enum value pulled from Bsn.Common (BeforeAll).
            if ((Get-BsnOperatingSystem) -ne $script:BsnWindows) {
                Set-ItResult -Skipped -Because 'requires a Windows host; on Unix the Windows-version guard throws first.'
            }
            # In CI/test context, both are typically redirected
            if ([Console]::IsInputRedirected -and [Console]::IsOutputRedirected) {
                { & (Get-Module -Name 'Bsn.Host') { Test-BsnRecordingEnvironment -Platform Windows } } | Should -Throw '*cannot capture output*'
            }
            else {
                Set-ItResult -Skipped -Because 'requires redirected stdio (CI context).'
            }
        }

        It 'warns (not throws) when only one handle is redirected (issue #8)' {
            # https://github.com/BSVN/Lmt.Commons/issues/8
            if ((Get-BsnOperatingSystem) -ne $script:BsnWindows) {
                Set-ItResult -Skipped -Because 'requires a Windows host; on Unix the Windows-version guard throws first.'
            }
            if ([Console]::IsInputRedirected -xor [Console]::IsOutputRedirected) {
                { & (Get-Module -Name 'Bsn.Host') { Test-BsnRecordingEnvironment -Platform Windows } } | Should -Not -Throw
            }
            else {
                Set-ItResult -Skipped -Because 'requires exactly one redirected handle.'
            }
        }
    }

    Context 'command encoding preserves shell metacharacters (issue #7)' {
        # https://github.com/BSVN/Lmt.Commons/issues/7
        It 'uses Base64 encoding instead of cmd.exe /d /c' {
            $commandLine = & (Get-Module -Name 'Bsn.Host') { Get-BsnRecordingCommandLine -Command 'echo hello' }
            $commandLine | Should -Not -BeLike '*cmd.exe*'
            $commandLine | Should -BeLike '*-EncodedCommand*'
        }

        It 'bootstraps the console codepage to UTF-8 in the recorded command session (issue #5)' {
            # https://github.com/BSVN/Lmt.Commons/issues/5
            # Byte-writing TUIs (Go/Bubble Tea such as OpenCode) emit UTF-8
            # bytes that OEM-codepage-decoding conhosts mangle; the recorded
            # session must set the console codepage to UTF-8 before the
            # command runs (the programmatic 'chcp 65001'). The command is
            # always wrapped in pwsh, so this holds on every platform.
            $commandLine = & (Get-Module -Name 'Bsn.Host') { param($c) Get-BsnRecordingCommandLine -Command $c } 'echo hello'
            $encoded = [regex]::Match($commandLine, '-EncodedCommand ([A-Za-z0-9+/=]+)').Groups[1].Value
            $decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
            $decoded.Contains('[Console]::OutputEncoding = [System.Text.Encoding]::UTF8') | Should -BeTrue
            $decoded.Contains('[Console]::InputEncoding = [System.Text.Encoding]::UTF8') | Should -BeTrue
            $decoded.Contains('echo hello') | Should -BeTrue
        }

        It 'bootstraps UTF-8 and auto-imports Bsn.Host in a PowerShell interactive session (issue #5)' {
            # The interactive shell is resolved per platform (pwsh/powershell
            # on Windows, $env:SHELL on Unix); mock it so the PowerShell
            # branch is exercised deterministically on every OS.
            Mock -CommandName Get-BsnDefaultShell -ModuleName 'Bsn.Host' { 'C:\Program Files\PowerShell\7\pwsh.exe' }

            $interactiveLine = & (Get-Module -Name 'Bsn.Host') { Get-BsnRecordingCommandLine }
            $interactiveLine.Contains('[Console]::OutputEncoding = [System.Text.Encoding]::UTF8') | Should -BeTrue
            $interactiveLine.Contains('Import-Module Bsn.Host') | Should -BeTrue
            $interactiveLine -like '*-NoLogo -NoExit*' | Should -BeTrue
        }

        It 'returns the bare shell path when the interactive shell is not PowerShell' {
            # Unix terminals are natively UTF-8 - the codepage bootstrap is a
            # Windows conhost concern - so a non-PowerShell default shell is
            # started as-is.
            Mock -CommandName Get-BsnDefaultShell -ModuleName 'Bsn.Host' { '/bin/bash' }

            & (Get-Module -Name 'Bsn.Host') { Get-BsnRecordingCommandLine } | Should -Be '/bin/bash'
        }

        It 'preserves shell metacharacters through Base64 round-trip' -TestCases @(
            @{ Original = "Write-Output A | Write-Host -NoNewline 'got: '" }
            @{ Original = 'Write-Output "hello | world" & more' }
            @{ Original = 'sort < input.txt > output.txt ^ special' }
        ) {
            param($Original)

            $commandLine = & (Get-Module -Name 'Bsn.Host') { param($c) Get-BsnRecordingCommandLine -Command $c } $Original

            if ($commandLine -match '-EncodedCommand\s+([A-Za-z0-9+/=]+)') {
                $decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
                # The wrapper prefixes the UTF-8 codepage bootstrap (issue #5);
                # the user's command must follow it verbatim.
                $decoded.Contains('[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; [Console]::InputEncoding = [System.Text.Encoding]::UTF8; ') | Should -BeTrue
                $decoded.EndsWith($Original) | Should -BeTrue
            }
            else {
                throw "Expected -EncodedCommand in command line but got: $commandLine"
            }
        }
    }

    Context 'stop signaling' {
        BeforeEach {
            Mock -CommandName Test-BsnRecordingEnvironment -ModuleName 'Bsn.Host' { }
            Mock -CommandName Get-BsnOperatingSystem -ModuleName 'Bsn.Host' { 'Windows' }
            Mock -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' {
                [pscustomobject]@{ ExitCode = 0; DurationSec = 1.0; StoppedByRequest = $true; Completed = $true }
            }
        }

        It 'passes a stop file to the engine and restores the environment afterwards' {
            $previousValue = $env:BsnHostRecordingStopFile

            Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'stop.cast')

            Should -Invoke -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' -Times 1 -Exactly -Scope It -ParameterFilter { $StopFilePath -and ($StopFilePath -like '*BsnHostRecordingStop_*.stop') }
            $env:BsnHostRecordingStopFile | Should -Be $previousValue
        }

        It 'reports when the recording was stopped by request' {
            $recording = Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'stop2.cast')
            $recording.StoppedByRequest | Should -BeTrue
        }
    }

    Context 'support for -WhatIf' {
        It 'records nothing under -WhatIf' {
            Mock -CommandName Test-BsnRecordingEnvironment -ModuleName 'Bsn.Host' { }
            Mock -CommandName Get-BsnOperatingSystem -ModuleName 'Bsn.Host' { 'Windows' }
            Mock -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' { }
            Mock -CommandName Start-BsnUnixPtyRecording -ModuleName 'Bsn.Host' { }

            Start-InteractiveTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'd.cast') -WhatIf

            Should -Invoke -CommandName Start-BsnWindowsPtyRecording -ModuleName 'Bsn.Host' -Times 0 -Exactly -Scope It
            Should -Invoke -CommandName Start-BsnUnixPtyRecording -ModuleName 'Bsn.Host' -Times 0 -Exactly -Scope It
        }
    }

    Context 'default shell resolution' {
        It 'returns an existing shell path' {
            $shellPath = & (Get-Module -Name 'Bsn.Host') { Get-BsnDefaultShell }
            $shellPath | Should -Not -BeNullOrEmpty
            (Get-Command -Name $shellPath -ErrorAction 'SilentlyContinue') | Should -Not -BeNullOrEmpty
        }
    }
}
