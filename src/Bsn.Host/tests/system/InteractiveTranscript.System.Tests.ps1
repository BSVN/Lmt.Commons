[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Scenario scripts run inside the recorded session; their console output is the payload under test.')]
param()

BeforeAll {
    $moduleRoot = Split-Path -Parent -Path (Split-Path -Parent -Path $PSScriptRoot)
    # Make the repo sibling module Bsn.Common resolvable for RequiredModules validation.
    $env:PSModulePath = '{0}{1}{2}' -f (Split-Path -Parent -Path $moduleRoot), [System.IO.Path]::PathSeparator, $env:PSModulePath
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

    $script:RepoRoot = Split-Path -Parent -Path (Split-Path -Parent -Path $moduleRoot)
    $script:HostModule = Get-Module -Name 'Bsn.Host'
    # Bsn.Common (loaded above via Bsn.Host's RequiredModules) owns platform
    # detection - reuse it instead of duplicating $PSVersionTable/$env:OS logic.
    # The enum value comes from the defining module's scope: a bare type
    # literal does not resolve from test scope, and a 'using module' header
    # here would execute before the PSModulePath fix above (see AGENTS.md).
    # IsWindowsPlatform is pure platform semantics (engine dispatch); the PS 7
    # console requirement is asserted per recording test with an explicit
    # "system tests require PowerShell 7 console infrastructure" skip.
    $script:BsnWindows = & (Get-Module -Name 'Bsn.Common') { [BsnOperatingSystem]::Windows }
    $script:IsWindowsPlatform = (Get-BsnOperatingSystem) -eq $script:BsnWindows
    $script:CanRunSystemTests = [bool](Get-Command -Name 'pwsh' -ErrorAction 'SilentlyContinue')
    $script:HasAsciinema = [bool](Get-Command -Name 'asciinema' -ErrorAction 'SilentlyContinue')
    $script:HasTmux = [bool](Get-Command -Name 'tmux' -ErrorAction 'SilentlyContinue')
    $script:HasConsoleLogger = [bool](Get-Command -Name 'conlog' -ErrorAction 'SilentlyContinue')

    # Plain-text rendering of a VT stream: strip CSI (ESC[...cmd) and OSC
    # (ESC]...BEL) sequences, then any remaining escape bytes. This is the
    # "real view" a terminal would show from the cast's output stream.
    function Convert-BsnCastPlainText {
        param([string]$RawStream)
        $esc = [char]27
        $text = $RawStream -replace ("{0}\[[0-9;?]*[a-zA-Z]" -f $esc), ''
        $text = $text -replace ("{0}\][^\a]*\a" -f $esc), ''
        $text = $text -replace ("[{0}]" -f $esc), ''
        return $text
    }

    function Get-BsnCastRawStream {
        param([string]$CastPath)
        $timeline = & $script:HostModule { param($p) Get-BsnCastTimeline -Path $p } $CastPath
        return (-join ($timeline.Events | Where-Object -FilterScript { $_[1] -eq 'o' } | ForEach-Object -Process { $_[2] }))
    }

    # Normalizes plain text for line-level comparison: strips PID (varies per run),
    # normalizes whitespace, removes empty lines.
    function Get-BsnNormalizedLine {
        param([string]$PlainText)
        $lines = $PlainText -split "`r?`n" |
            ForEach-Object -Process { ($_ -replace 'SYSMARK-PID: \d+', 'SYSMARK-PID: <pid>').Trim() } |
            Where-Object -FilterScript { $_ }
        return $lines
    }

    # All content markers the cross-check tools must find in their recordings.
    $script:ContentMarkers = @(
        'SYSMARK-A: recorded session start'
        'SYSMARK-PID: '
        'TUI-FRAME: simulated full-screen application'
        'SYSMARK-B: after TUI exit'
    )

    # Scenario: simple cmdlets + a simulated TUI application (alternate screen
    # buffer, clear, home, frame content - exactly what ncurses-style apps emit).
    function Get-BsnScenarioScript {
        param([string]$Directory, [switch]$WithLongSleep)

        $scenarioPath = Join-Path -Path $Directory -ChildPath 'scenario.ps1'
        $sleepBlock = if ($WithLongSleep.IsPresent) { 'Start-Sleep -Seconds 120' } else { 'Start-Sleep -Milliseconds 300' }
        $trailingMarker = if ($WithLongSleep.IsPresent) { '# long sleep - the after-marker below must NOT reach the cast' } else { "Write-Output 'SYSMARK-B: after TUI exit'" }

        $scenario = @"
`$ErrorActionPreference = 'Stop'
`$esc = [char]27
Write-Output 'SYSMARK-A: recorded session start'
Write-Output ('SYSMARK-PID: ' + `$PID)
[Console]::Out.Write(`$esc + '[?1049h')
[Console]::Out.Write(`$esc + '[2J')
[Console]::Out.Write(`$esc + '[H')
Write-Output 'TUI-FRAME: simulated full-screen application'
$sleepBlock
[Console]::Out.Write(`$esc + '[?1049l')
$trailingMarker
"@
        $scenario | Set-Content -LiteralPath $scenarioPath -Encoding UTF8
        return $scenarioPath
    }

    # Windows CI/harness sessions have redirected stdio, which routes child
    # output around the ConPTY (verified). The proven workaround: run the
    # public cmdlet inside a hidden-console pwsh and report results via JSON.
    function Invoke-BsnHiddenConsoleRecording {
        param(
            [string]$ScenarioPath,
            [string]$CastPath,
            [switch]$StopAfterDelay
        )

        $workDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('bsn-systest-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType 'Directory' -Path $workDirectory -Force
        $resultPath = Join-Path -Path $workDirectory -ChildPath 'result.json'
        $stderrPath = Join-Path -Path $workDirectory -ChildPath 'runner.err'
        $runnerPath = Join-Path -Path $workDirectory -ChildPath 'runner.ps1'

        $stopBlock = if ($StopAfterDelay.IsPresent) {
            @'
$stopJob = Start-ThreadJob -ScriptBlock {
    Start-Sleep -Seconds 6
    $stopFile = $env:BsnHostRecordingStopFile
    if ($stopFile -and -not (Test-Path -LiteralPath $stopFile)) {
        Set-Content -LiteralPath $stopFile -Value 'stop'
    }
}
'@
        }
        else { '' }

        $recordingBlock = if ($StopAfterDelay.IsPresent) {
            'try { $result = Start-InteractiveTranscript -Command (''pwsh -NoProfile -File '' + $ScenarioPath) -Path $CastPath } finally { if ($stopJob) { $stopJob | Wait-Job -Timeout 15 | Out-Null; $stopJob | Remove-Job -Force -ErrorAction SilentlyContinue } }'
        }
        else {
            '$result = Start-InteractiveTranscript -Command (''pwsh -NoProfile -File '' + $ScenarioPath) -Path $CastPath'
        }

        $runner = @"
param(`$RepoRoot, `$ScenarioPath, `$CastPath, `$ResultPath)
`$ErrorActionPreference = 'Stop'
Import-Module (Join-Path `$RepoRoot 'src/Bsn.Common/Bsn.Common.psd1') -Force
Import-Module (Join-Path `$RepoRoot 'src/Bsn.Host/Bsn.Host.psd1') -Force
$stopBlock
$recordingBlock
@{ CastPath = `$result.CastPath; ExitCode = `$result.ExitCode; DurationSec = `$result.DurationSec; StoppedByRequest = `$result.StoppedByRequest } |
    ConvertTo-Json | Set-Content -LiteralPath `$ResultPath
"@
        $runner | Set-Content -LiteralPath $runnerPath -Encoding UTF8

        try {
            $process = Start-Process -FilePath 'pwsh' `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runnerPath,
                    '-RepoRoot', ('"{0}"' -f $script:RepoRoot),
                    '-ScenarioPath', ('"{0}"' -f $ScenarioPath),
                    '-CastPath', ('"{0}"' -f $CastPath),
                    '-ResultPath', ('"{0}"' -f $resultPath)) `
                -WindowStyle 'Hidden' -RedirectStandardError $stderrPath -PassThru

            if (-not $process.WaitForExit(180000)) {
                $process.Kill()
                throw 'Hidden-console recording runner timed out after 180 seconds.'
            }

            if (-not (Test-Path -LiteralPath $resultPath)) {
                $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '<no stderr>' }
                throw ("Recording runner produced no result (exit code {0}). Stderr: {1}" -f $process.ExitCode, $stderr)
            }

            return (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
        }
        finally {
            Remove-Item -LiteralPath $workDirectory -Recurse -Force -ErrorAction 'SilentlyContinue'
        }
    }

    function Invoke-BsnSystemRecording {
        param(
            [string]$ScenarioPath,
            [string]$CastPath,
            [switch]$StopAfterDelay
        )

        if ($script:IsWindowsPlatform) {
            return (Invoke-BsnHiddenConsoleRecording -ScenarioPath $ScenarioPath -CastPath $CastPath -StopAfterDelay:$StopAfterDelay.IsPresent)
        }

        # Unix: script(1) allocates its own PTY, so the public cmdlet works
        # in-process even under CI's redirected stdio.
        $stopJob = $null
        if ($StopAfterDelay.IsPresent) {
            $stopJob = Start-ThreadJob -ScriptBlock {
                Start-Sleep -Seconds 6
                $stopFile = $env:BsnHostRecordingStopFile
                if ($stopFile -and -not (Test-Path -LiteralPath $stopFile)) {
                    Set-Content -LiteralPath $stopFile -Value 'stop'
                }
            }
        }

        try {
            $command = 'pwsh -NoProfile -File ' + $ScenarioPath
            return (Start-InteractiveTranscript -Command $command -Path $CastPath)
        }
        finally {
            if ($stopJob) {
                $stopJob | Wait-Job -Timeout 15 | Out-Null
                $stopJob | Remove-Job -Force -ErrorAction 'SilentlyContinue'
            }
        }
    }

    # === Issue #20 probe: plays a cast back in a hidden console and reports
    # how many console INPUT records accumulated during playback. Terminals
    # answer query sequences (DSR, XTWINOPS pixel size, DA, kitty keyboard,
    # OSC color queries) by writing response records into the console input
    # buffer; playback that re-emits the queries therefore pollutes the
    # prompt (PSReadLine shows the response text as typed input).
    function Invoke-BsnPlaybackInputBufferProbe {
        param([string]$CastPath)

        $workDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('bsn-playbackprobe-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType 'Directory' -Path $workDirectory -Force
        $resultPath = Join-Path -Path $workDirectory -ChildPath 'result.json'
        $stderrPath = Join-Path -Path $workDirectory -ChildPath 'runner.err'
        $runnerPath = Join-Path -Path $workDirectory -ChildPath 'runner.ps1'

        $runner = @"
param(`$RepoRoot, `$CastPath, `$ResultPath)
`$ErrorActionPreference = 'Stop'
Import-Module (Join-Path `$RepoRoot 'src/Bsn.Common/Bsn.Common.psd1') -Force
Import-Module (Join-Path `$RepoRoot 'src/Bsn.Host/Bsn.Host.psd1') -Force
`$before = [Bsn.Host.Interop.ConsoleInputInterop]::GetInputRecordCount()
Show-InteractiveTranscript -Path `$CastPath -Speed 100
Start-Sleep -Seconds 2   # let the terminal's query responses settle
`$after = [Bsn.Host.Interop.ConsoleInputInterop]::GetInputRecordCount()
@{ Before = `$before; After = `$after } | ConvertTo-Json | Set-Content -LiteralPath `$ResultPath
"@
        $runner | Set-Content -LiteralPath $runnerPath -Encoding UTF8

        try {
            $process = Start-Process -FilePath 'pwsh' `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runnerPath,
                    '-RepoRoot', ('"{0}"' -f $script:RepoRoot),
                    '-CastPath', ('"{0}"' -f $CastPath),
                    '-ResultPath', ('"{0}"' -f $resultPath)) `
                -WindowStyle 'Hidden' -RedirectStandardError $stderrPath -PassThru

            if (-not $process.WaitForExit(120000)) {
                $process.Kill()
                throw 'Playback input-buffer probe timed out after 120 seconds.'
            }

            if (-not (Test-Path -LiteralPath $resultPath)) {
                $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '<no stderr>' }
                throw ("Playback probe produced no result (exit code {0}). Stderr: {1}" -f $process.ExitCode, $stderr)
            }

            return (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
        }
        finally {
            Remove-Item -LiteralPath $workDirectory -Recurse -Force -ErrorAction 'SilentlyContinue'
        }
    }

    # === Cross-check source: asciinema (Linux) ===
    # Records via asciinema rec, the reference implementation of the asciicast
    # format. Returns the path to the independent .cast file.
    function Invoke-BsnAsciinemaRecording {
        param([string]$ScenarioPath, [string]$OutputPath)

        $asciinema = Get-Command -Name 'asciinema' -ErrorAction 'Stop'
        $command = 'pwsh -NoProfile -File ' + $ScenarioPath
        & $asciinema.Source rec --quiet --command $command --overwrite $OutputPath
        if ($LASTEXITCODE -ne 0) {
            throw ("asciinema rec failed with exit code {0}." -f $LASTEXITCODE)
        }
        return $OutputPath
    }

    # === Cross-check source: tmux pipe-pane (Linux) ===
    # Records via tmux's own PTY mechanism - a completely independent
    # terminal multiplexer infrastructure. Returns the raw capture file path.
    function Invoke-BsnTmuxRecording {
        param([string]$ScenarioPath, [string]$OutputPath)

        $tmux = Get-Command -Name 'tmux' -ErrorAction 'Stop'
        $sessionName = 'bsn-crosscheck-' + [guid]::NewGuid().ToString('N').Substring(0, 8)

        # Create detached session running the scenario, pipe all pane output
        & $tmux.Source new-session -d -s $sessionName "pwsh -NoProfile -File '$ScenarioPath'"
        & $tmux.Source pipe-pane -t $sessionName "cat > '$OutputPath'"

        # Wait for the session to end (scenario completes)
        $timeout = 60
        $elapsed = 0
        while ($elapsed -lt $timeout) {
            $sessions = & $tmux.Source list-sessions -F '#{session_name}' 2>$null
            if ($sessions -notcontains $sessionName) { break }
            Start-Sleep -Milliseconds 500
            $elapsed += 0.5
        }

        # Clean up
        & $tmux.Source kill-session -t $sessionName 2>$null
        & $tmux.Source pipe-pane -t $sessionName 2>$null

        if (-not (Test-Path -LiteralPath $OutputPath)) {
            throw 'tmux pipe-pane did not produce an output file.'
        }
        return $OutputPath
    }

    # === Cross-check source: console-logger (Windows) ===
    # Records via rhubarb-geek-nz/console-logger, an independent ConPTY wrapper
    # (cited in RFC 421 as proof-of-concept). Captures raw VT output.
    # Requires conlog.exe on PATH (build from https://github.com/rhubarb-geek-nz/console-logger).
    function Invoke-BsnConsoleLoggerRecording {
        param([string]$ScenarioPath, [string]$OutputPath)

        $conlog = Get-Command -Name 'conlog' -ErrorAction 'Stop'
        $command = 'pwsh -NoProfile -File ' + $ScenarioPath
        & $conlog.Source $command *> $OutputPath
        if ($LASTEXITCODE -ne 0) {
            throw ("conlog failed with exit code {0}." -f $LASTEXITCODE)
        }
        return $OutputPath
    }
}

Describe 'InteractiveTranscript system tests' -Tag 'SystemTest' {
    Context 'truth-table cross-check: cast view vs ground truth' {
        It 'the cast view matches the unrecorded ground truth output (marker + line level)' {
            if (-not $script:CanRunSystemTests) {
                Set-ItResult -Skipped -Because 'pwsh is required to run recorded scenarios and was not found.'
            }
            if ($PSVersionTable.PSVersion.Major -lt 7) {
                Set-ItResult -Skipped -Because 'system tests require PowerShell 7 console infrastructure.'
            }
            if (-not $script:IsWindowsPlatform -and ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected)) {
                Set-ItResult -Skipped -Because 'the Unix script(1) engine is unreliable under CI redirected stdio; run locally.'
            }

            $scenarioPath = Get-BsnScenarioScript -Directory $TestDrive
            $castPath = Join-Path -Path $TestDrive -ChildPath 'crosscheck.cast'

            # === SOURCE 1: ground truth (no recording tool at all) ===
            $truthPath = Join-Path -Path $TestDrive -ChildPath 'truth.txt'
            $null = & pwsh -NoProfile -File $scenarioPath *> $truthPath
            $truthText = Convert-BsnCastPlainText -RawStream (Get-Content -LiteralPath $truthPath -Raw)

            # === SOURCE 2: recorded by Start-InteractiveTranscript ===
            $result = Invoke-BsnSystemRecording -ScenarioPath $scenarioPath -CastPath $castPath
            $result.ExitCode | Should -Be 0
            $castPlainText = Convert-BsnCastPlainText -RawStream (Get-BsnCastRawStream -CastPath $castPath)

            # === MARKER CHECK: every marker present in both sources ===
            foreach ($marker in $script:ContentMarkers) {
                $truthIndex = $truthText.IndexOf($marker)
                $castIndex = $castPlainText.IndexOf($marker)
                $truthIndex | Should -BeGreaterThan (-1) -Because ("the ground truth output must contain '{0}'" -f $marker)
                $castIndex | Should -BeGreaterThan (-1) -Because ("the recorded cast view must contain '{0}'" -f $marker)
            }

            # === LINE-LEVEL CHECK: every normalized line in ground truth appears in the cast ===
            $truthLines = Get-BsnNormalizedLine -PlainText $truthText
            $castLines = Get-BsnNormalizedLine -PlainText $castPlainText

            foreach ($truthLine in $truthLines) {
                $truthLine | Should -BeIn $castLines -Because ("every line of the ground truth output must appear in the recorded cast view (line: '{0}')" -f $truthLine)
            }

            # === ORDER CHECK: markers appear in the same sequence ===
            $castIndices = @($script:ContentMarkers | ForEach-Object -Process { $castPlainText.IndexOf($_) })
            for ($i = 1; $i -lt $script:ContentMarkers.Count; $i++) {
                $castIndices[$i] | Should -BeGreaterThan $castIndices[$i - 1] -Because ("marker order preserved: '{0}' after '{1}'" -f $script:ContentMarkers[$i], $script:ContentMarkers[$i - 1])
            }
        }
    }

    Context 'cross-check against asciinema (reference asciicast implementation)' -Tag 'SystemTest' {
        It 'our cast and asciinema rec capture the same content (Linux only)' {
            if (-not $script:CanRunSystemTests -or $PSVersionTable.PSVersion.Major -lt 7) {
                Set-ItResult -Skipped -Because 'requires pwsh 7.'
            }
            if ($script:IsWindowsPlatform) {
                Set-ItResult -Skipped -Because 'asciinema does not support Windows; use console-logger cross-check instead.'
            }
            if (-not $script:HasAsciinema) {
                Set-ItResult -Skipped -Because 'asciinema is not installed (pip install asciinema). Install it to run this cross-check.'
            }
            if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
                Set-ItResult -Skipped -Because 'requires an interactive terminal (CI has redirected stdio).'
            }

            $scenarioPath = Get-BsnScenarioScript -Directory $TestDrive

            # Record with asciinema (reference implementation)
            $asciinemaCastPath = Join-Path -Path $TestDrive -ChildPath 'asciinema-rec.cast'
            $null = Invoke-BsnAsciinemaRecording -ScenarioPath $scenarioPath -OutputPath $asciinemaCastPath
            Test-Path -LiteralPath $asciinemaCastPath | Should -BeTrue

            # Record with our tool
            $ourCastPath = Join-Path -Path $TestDrive -ChildPath 'our-rec.cast'
            $result = Invoke-BsnSystemRecording -ScenarioPath $scenarioPath -CastPath $ourCastPath
            $result.ExitCode | Should -Be 0

            # Parse both casts and compare output content
            $asciinemaRaw = Get-BsnCastRawStream -CastPath $asciinemaCastPath
            $ourRaw = Get-BsnCastRawStream -CastPath $ourCastPath

            $asciinemaText = Convert-BsnCastPlainText -RawStream $asciinemaRaw
            $ourText = Convert-BsnCastPlainText -RawStream $ourRaw

            foreach ($marker in $script:ContentMarkers) {
                $asciinemaText.IndexOf($marker) | Should -BeGreaterThan (-1) -Because ("asciinema's recording must contain '{0}'" -f $marker)
                $ourText.IndexOf($marker) | Should -BeGreaterThan (-1) -Because ("our recording must contain '{0}' (asciinema does too)" -f $marker)
            }

            # Both casts contain the TUI alt-screen sequences
            $esc = [char]27
            $asciinemaRaw.Contains($esc + '[?1049h') | Should -BeTrue -Because 'asciinema captured the alt-screen enter'
            $ourRaw.Contains($esc + '[?1049h') | Should -BeTrue -Because 'our recording captured the alt-screen enter (asciinema does too)'
        }
    }

    Context 'cross-check against tmux pipe-pane (independent PTY mechanism)' -Tag 'SystemTest' {
        It 'our cast and tmux capture the same content (Linux only)' {
            if (-not $script:CanRunSystemTests -or $PSVersionTable.PSVersion.Major -lt 7) {
                Set-ItResult -Skipped -Because 'requires pwsh 7.'
            }
            if ($script:IsWindowsPlatform) {
                Set-ItResult -Skipped -Because 'tmux is not available on Windows.'
            }
            if (-not $script:HasTmux) {
                Set-ItResult -Skipped -Because 'tmux is not installed. Install it to run this cross-check.'
            }
            if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
                Set-ItResult -Skipped -Because 'requires an interactive terminal for tmux (CI has redirected stdio).'
            }

            $scenarioPath = Get-BsnScenarioScript -Directory $TestDrive

            # Record with tmux pipe-pane
            $tmuxLogPath = Join-Path -Path $TestDrive -ChildPath 'tmux-capture.log'
            $null = Invoke-BsnTmuxRecording -ScenarioPath $scenarioPath -OutputPath $tmuxLogPath
            Test-Path -LiteralPath $tmuxLogPath | Should -BeTrue

            # Record with our tool
            $ourCastPath = Join-Path -Path $TestDrive -ChildPath 'our-tmux-rec.cast'
            $result = Invoke-BsnSystemRecording -ScenarioPath $scenarioPath -CastPath $ourCastPath
            $result.ExitCode | Should -Be 0

            # Compare content
            $tmuxText = Convert-BsnCastPlainText -RawStream (Get-Content -LiteralPath $tmuxLogPath -Raw)
            $ourText = Convert-BsnCastPlainText -RawStream (Get-BsnCastRawStream -CastPath $ourCastPath)

            foreach ($marker in $script:ContentMarkers) {
                $tmuxText.IndexOf($marker) | Should -BeGreaterThan (-1) -Because ("tmux's PTY capture must contain '{0}'" -f $marker)
                $ourText.IndexOf($marker) | Should -BeGreaterThan (-1) -Because ("our recording must contain '{0}' (tmux does too)" -f $marker)
            }
        }
    }

    Context 'cross-check against console-logger (independent ConPTY tool, Windows)' -Tag 'SystemTest' {
        It 'our cast and console-logger capture the same content (Windows only)' {
            if (-not $script:CanRunSystemTests -or $PSVersionTable.PSVersion.Major -lt 7) {
                Set-ItResult -Skipped -Because 'requires pwsh 7.'
            }
            if (-not $script:IsWindowsPlatform) {
                Set-ItResult -Skipped -Because 'console-logger is Windows-only; use asciinema/tmux cross-check instead.'
            }
            if (-not $script:HasConsoleLogger) {
                Set-ItResult -Skipped -Because 'conlog.exe is not on PATH (build from https://github.com/rhubarb-geek-nz/console-logger).'
            }
            if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
                Set-ItResult -Skipped -Because 'conlog requires console-attached stdio (it reads its own console input); run locally in a terminal - the live-view codepage test covers conlog end to end under CI-safe hidden consoles.'
            }

            $scenarioPath = Get-BsnScenarioScript -Directory $TestDrive

            # Record with console-logger (independent ConPTY wrapper)
            $conlogPath = Join-Path -Path $TestDrive -ChildPath 'conlog-output.txt'
            $null = Invoke-BsnConsoleLoggerRecording -ScenarioPath $scenarioPath -OutputPath $conlogPath
            Test-Path -LiteralPath $conlogPath | Should -BeTrue

            # Record with our tool (hidden-console runner)
            $ourCastPath = Join-Path -Path $TestDrive -ChildPath 'our-conlog-rec.cast'
            $result = Invoke-BsnSystemRecording -ScenarioPath $scenarioPath -CastPath $ourCastPath
            $result.ExitCode | Should -Be 0

            # Compare content
            $conlogText = Convert-BsnCastPlainText -RawStream (Get-Content -LiteralPath $conlogPath -Raw)
            $ourText = Convert-BsnCastPlainText -RawStream (Get-BsnCastRawStream -CastPath $ourCastPath)

            foreach ($marker in $script:ContentMarkers) {
                $conlogText.IndexOf($marker) | Should -BeGreaterThan (-1) -Because ("console-logger's recording must contain '{0}'" -f $marker)
                $ourText.IndexOf($marker) | Should -BeGreaterThan (-1) -Because ("our recording must contain '{0}' (console-logger does too)" -f $marker)
            }

            # Both contain TUI alt-screen sequences
            $esc = [char]27
            $conlogRaw = Get-Content -LiteralPath $conlogPath -Raw
            $ourRaw = Get-BsnCastRawStream -CastPath $ourCastPath
            $conlogRaw.Contains($esc + '[?1049h') | Should -BeTrue -Because 'console-logger captured the alt-screen enter'
            $ourRaw.Contains($esc + '[?1049h') | Should -BeTrue -Because 'our recording captured the alt-screen enter (console-logger does too)'
        }
    }

    Context 'Issue #5: large multi-byte burst survives without U+FFFD corruption' {
        # https://github.com/BSVN/Lmt.Commons/issues/5
        It 'records 60000 multi-byte characters with zero U+FFFD in the cast' {
            if (-not $script:CanRunSystemTests) {
                Set-ItResult -Skipped -Because 'pwsh is required to run recorded scenarios and was not found.'
            }
            if ($PSVersionTable.PSVersion.Major -lt 7) {
                Set-ItResult -Skipped -Because 'system tests require PowerShell 7 console infrastructure.'
            }
            if (-not $script:IsWindowsPlatform -and ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected)) {
                Set-ItResult -Skipped -Because 'the Unix script(1) engine is unreliable under CI redirected stdio; run locally.'
            }

            # Scenario: write 60000 copies of a 3-byte UTF-8 character (U+2580).
            # Total: 180KB — far exceeds the 4096-byte read buffer, guaranteeing
            # many multi-byte sequences span chunk boundaries.
            $scenarioDir = Join-Path -Path $TestDrive -ChildPath 'utf8-burst'
            $null = New-Item -ItemType Directory -Path $scenarioDir -Force
            $scenarioPath = Join-Path -Path $scenarioDir -ChildPath 'scenario-utf8.ps1'
            @'
$ErrorActionPreference = 'Stop'
$blockChar = [string][char]0x2580
[Console]::Out.Write($blockChar * 60000)
Write-Output ''
Write-Output 'UTF8-BURST-DONE'
'@ | Set-Content -LiteralPath $scenarioPath -Encoding UTF8

            $castPath = Join-Path -Path $TestDrive -ChildPath 'utf8-burst.cast'
            $result = Invoke-BsnSystemRecording -ScenarioPath $scenarioPath -CastPath $castPath
            $result.ExitCode | Should -Be 0

            # Parse every event and check for U+FFFD
            $null = & $script:HostModule { param($p) Get-BsnCastTimeline -Path $p } $castPath
            $rawStream = Get-BsnCastRawStream -CastPath $castPath

            # The marker must be present (the recording captured the output)
            $rawStream.IndexOf('UTF8-BURST-DONE') | Should -BeGreaterThan (-1) -Because 'the burst completion marker must be captured'

            # Count U+FFFD occurrences: must be ZERO
            $replacementCount = ([regex]::Matches($rawStream, [regex]::Escape([string][char]0xFFFD))).Count
            $replacementCount | Should -Be 0 -Because ("cast must contain zero U+FFFD replacement characters (found {0}); multi-byte UTF-8 sequences must not be corrupted at chunk boundaries (issue #5)" -f $replacementCount)

            # The multi-byte character must actually be present (not just absent of corruption)
            $blockCharString = [string][char]0x2580
            $rawStream.Contains($blockCharString) | Should -BeTrue -Because 'the block character U+2580 must appear in the cast'
        }
    }

    Context 'Issue #5: oh-my-posh prompt rendering (real-world multi-byte stress test)' {
        # https://github.com/BSVN/Lmt.Commons/issues/5
        # oh-my-posh renders powerline/nerd-font glyphs (3-4 byte UTF-8 sequences
        # in the Supplementary Private Use Area). A single prompt with many segments
        # easily exceeds the 4096-byte read buffer, guaranteeing chunk-boundary
        # splits mid-glyph. This is the real-world case the issue was filed for.
        It 'records an oh-my-posh prompt burst with zero U+FFFD in the cast' {
            if (-not $script:CanRunSystemTests) {
                Set-ItResult -Skipped -Because 'pwsh is required to run recorded scenarios and was not found.'
            }
            if ($PSVersionTable.PSVersion.Major -lt 7) {
                Set-ItResult -Skipped -Because 'system tests require PowerShell 7 console infrastructure.'
            }
            if (-not $script:IsWindowsPlatform) {
                Set-ItResult -Skipped -Because 'oh-my-posh test is Windows-only (Linux uses vim TUI test instead).'
            }

            # oh-my-posh must be on PATH (CI installs it; locally: winget install JanDeDobbeleer.OhMyPosh)
            $ohMyPosh = Get-Command -Name 'oh-my-posh' -ErrorAction 'SilentlyContinue'
            if (-not $ohMyPosh) {
                Set-ItResult -Skipped -Because 'oh-my-posh is not on PATH. Install it (winget install JanDeDobbeleer.OhMyPosh) to run this stress test.'
            }

            # Scenario: render multiple oh-my-posh prompts (each produces multi-byte glyphs)
            $scenarioDir = Join-Path -Path $TestDrive -ChildPath 'ohmyposh'
            $null = New-Item -ItemType Directory -Path $scenarioDir -Force
            $scenarioPath = Join-Path -Path $scenarioDir -ChildPath 'scenario-omp.ps1'

            $themePath = if ($env:POSH_THEMES_PATH) {
                Join-Path -Path $env:POSH_THEMES_PATH -ChildPath 'atomic.omp.json'
            } else {
                # Try a known install location
                Join-Path -Path "$env:LOCALAPPDATA\Programs\oh-my-posh\themes" -ChildPath 'atomic.omp.json'
            }

            $themeBlock = if (Test-Path -LiteralPath $themePath) {
                " --config `"$themePath`""
            } else {
                ''  # use the default theme
            }

            @"
`$ErrorActionPreference = 'Stop'
# Render multiple prompts via oh-my-posh print primary (produces the glyph-laden output)
# Each prompt is typically 200-600 bytes of multi-byte VT sequences
1..20 | ForEach-Object { oh-my-posh print primary --shell pwsh$themeBlock }
Write-Output 'OMP-STRESS-DONE'
"@ | Set-Content -LiteralPath $scenarioPath -Encoding UTF8

            $castPath = Join-Path -Path $TestDrive -ChildPath 'omp-stress.cast'
            $result = Invoke-BsnSystemRecording -ScenarioPath $scenarioPath -CastPath $castPath
            $result.ExitCode | Should -Be 0

            $rawStream = Get-BsnCastRawStream -CastPath $castPath

            # The marker must be present
            $rawStream.IndexOf('OMP-STRESS-DONE') | Should -BeGreaterThan (-1) -Because 'the oh-my-posh stress test completion marker must be captured'

            # Count U+FFFD occurrences: must be ZERO
            $replacementCount = ([regex]::Matches($rawStream, [regex]::Escape([string][char]0xFFFD))).Count
            $replacementCount | Should -Be 0 -Because ("cast must contain zero U+FFFD replacement characters after oh-my-posh prompt rendering (found {0}); nerd-font glyphs must survive chunk boundaries without corruption (issue #5)" -f $replacementCount)
        }
    }

    Context 'Issue #5: vim TUI session (hardest Linux TUI case)' {
        # https://github.com/BSVN/Lmt.Commons/issues/5
        # vim is one of the hardest TUI cases: full-screen rendering, alternate
        # screen buffer, cursor positioning, syntax highlighting, status line,
        # and multi-byte content. This test validates that the recording captures
        # a real vim session correctly.
        It 'records a vim session and captures the TUI content' {
            if (-not $script:CanRunSystemTests) {
                Set-ItResult -Skipped -Because 'pwsh is required to run recorded scenarios and was not found.'
            }
            if ($PSVersionTable.PSVersion.Major -lt 7) {
                Set-ItResult -Skipped -Because 'system tests require PowerShell 7 console infrastructure.'
            }
            if ($script:IsWindowsPlatform) {
                Set-ItResult -Skipped -Because 'vim TUI test is Linux-only (Windows uses oh-my-posh test instead).'
            }
            if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
                Set-ItResult -Skipped -Because 'requires an interactive terminal (CI has redirected stdio); run locally.'
            }

            $vimCommand = Get-Command -Name 'vim' -ErrorAction 'SilentlyContinue'
            if (-not $vimCommand) {
                # Try vi as a fallback
                $vimCommand = Get-Command -Name 'vi' -ErrorAction 'SilentlyContinue'
            }
            if (-not $vimCommand) {
                Set-ItResult -Skipped -Because 'vim/vi is not installed. Install it to run this TUI stress test.'
            }

            # Create a file with distinctive content for vim to render
            $contentFile = Join-Path -Path $TestDrive -ChildPath 'vim-content.txt'
            @'
VIM-TUI-LINE-1: The quick brown fox
VIM-TUI-LINE-2: jumps over the lazy dog
VIM-TUI-LINE-3: pack my box with five dozen liquor jugs
VIM-TUI-LINE-4: ================================
VIM-TUI-LINE-5: [SUCCESS] All systems operational
VIM-TUI-LINE-6: © 2026 UTF-8 test — ¥€£¢
VIM-TUI-LINE-7: ┌──────────────────────────┐
VIM-TUI-LINE-8: │ Box-drawing characters  │
VIM-TUI-LINE-9: └──────────────────────────┘
'@ | Set-Content -LiteralPath $contentFile -Encoding UTF8

            # Scenario: open vim with the content file, wait briefly, quit
            # vim enters alt-screen, renders the file with line numbers,
            # status line, and the content - then exits alt-screen on :q
            $scenarioDir = Join-Path -Path $TestDrive -ChildPath 'vim-tui'
            $null = New-Item -ItemType Directory -Path $scenarioDir -Force
            $scenarioPath = Join-Path -Path $scenarioDir -ChildPath 'scenario-vim.sh'

            $vimScript = @"
#!/bin/sh
# Open vim with the content file, auto-quit after loading
vim -R -c 'sleep 1' -c 'q' '$contentFile' 2>/dev/null || vi -R -c 'q' '$contentFile' 2>/dev/null
echo 'VIM-TUI-DONE'
"@
            $vimScript | Set-Content -LiteralPath $scenarioPath -Encoding UTF8
            $null = & chmod +x $scenarioPath

            $castPath = Join-Path -Path $TestDrive -ChildPath 'vim-tui.cast'
            $result = Invoke-BsnSystemRecording -ScenarioPath $scenarioPath -CastPath $castPath
            $result.ExitCode | Should -Be 0

            $rawStream = Get-BsnCastRawStream -CastPath $castPath
            $plainText = Convert-BsnCastPlainText -RawStream $rawStream

            # TUI capture: alternate screen enter/exit must be present
            $esc = [char]27
            $rawStream.Contains($esc + '[?1049h') | Should -BeTrue -Because 'vim must enter the alternate screen buffer'
            $rawStream.Contains($esc + '[?1049l') | Should -BeTrue -Because 'vim must exit the alternate screen buffer'

            # Content capture: vim rendered the file content on screen
            $plainText.IndexOf('VIM-TUI-LINE-1') | Should -BeGreaterThan (-1) -Because 'vim rendered the first line'
            $plainText.IndexOf('VIM-TUI-LINE-5') | Should -BeGreaterThan (-1) -Because 'vim rendered the success line'

            # Multi-byte content: the UTF-8 and box-drawing lines must survive
            $plainText.IndexOf('UTF-8 test') | Should -BeGreaterThan (-1) -Because 'vim rendered multi-byte UTF-8 content'
            $plainText.IndexOf('Box-drawing') | Should -BeGreaterThan (-1) -Because 'vim rendered box-drawing characters'

            # No corruption
            $replacementCount = ([regex]::Matches($rawStream, [regex]::Escape([string][char]0xFFFD))).Count
            $replacementCount | Should -Be 0 -Because ("vim TUI recording must contain zero U+FFFD (found {0}); multi-byte content must survive chunk boundaries (issue #5)" -f $replacementCount)
        }
    }

    Context 'Issue #5: console codepage bootstrap (byte-writing TUIs such as OpenCode)' {
        # https://github.com/BSVN/Lmt.Commons/issues/5
        # Second root cause of the reported recording corruption: a fresh
        # pseudo console starts with the OEM output codepage (e.g. 437 - the
        # probe 'chcp.com' proves it), and OEM-codepage-decoding conhosts
        # decode a child's stdout BYTES with that codepage. Byte-writing TUIs
        # (Go/Bubble Tea applications such as OpenCode, Node raw writes,
        # 'cmd /c type') emit UTF-8 bytes, so every multi-byte character is
        # mangled BEFORE the recorder sees a single byte: one box-drawing
        # character (U+2500, UTF-8 E2 94 80) arrives as three CP-decoded
        # characters (CP437 'Gamma ohmega-acute'). pwsh's own output is
        # immune (it writes through WriteConsoleW), which is why synthetic
        # pwsh probes passed while real byte-writing TUIs were corrupted.
        # The wrapper therefore bootstraps [Console]::OutputEncoding /
        # InputEncoding to UTF-8 (the programmatic 'chcp 65001') before the
        # recorded command runs.

        It 'records a session whose console codepage is UTF-8 (65001)' {
            if (-not $script:CanRunSystemTests) {
                Set-ItResult -Skipped -Because 'pwsh is required to run recorded scenarios and was not found.'
            }
            if ($PSVersionTable.PSVersion.Major -lt 7) {
                Set-ItResult -Skipped -Because 'system tests require PowerShell 7 console infrastructure.'
            }
            if (-not $script:IsWindowsPlatform) {
                Set-ItResult -Skipped -Because 'the codepage bootstrap is a ConPTY (Windows engine) behavior.'
            }

            $scenarioPath = Join-Path -Path $TestDrive -ChildPath 'scenario-chcp.ps1'
            'chcp.com' | Set-Content -LiteralPath $scenarioPath -Encoding UTF8

            $castPath = Join-Path -Path $TestDrive -ChildPath 'codepage.cast'
            $result = Invoke-BsnSystemRecording -ScenarioPath $scenarioPath -CastPath $castPath
            $result.ExitCode | Should -Be 0

            $rawStream = Get-BsnCastRawStream -CastPath $castPath
            $rawStream.Contains('65001') | Should -BeTrue -Because ('the recorded session must bootstrap the console codepage to UTF-8 (conhost decodes child output bytes with it; a fresh pseudo console starts at the OEM codepage); the recorded chcp output was: ' + ($rawStream -replace '\u001b', '^['))
        }

        It 'records a BYTE-WRITING child (raw console-handle output, Go/Node TUI style) without corruption' {
            if (-not $script:CanRunSystemTests) {
                Set-ItResult -Skipped -Because 'pwsh is required to run recorded scenarios and was not found.'
            }
            if ($PSVersionTable.PSVersion.Major -lt 7) {
                Set-ItResult -Skipped -Because 'system tests require PowerShell 7 console infrastructure.'
            }
            if (-not $script:IsWindowsPlatform) {
                Set-ItResult -Skipped -Because 'the codepage bootstrap is a ConPTY (Windows engine) behavior.'
            }

            # The probe file holds UTF-8 bytes for box-drawing borders plus an
            # ASCII marker - exactly the payload shape of a byte-writing TUI.
            $probePath = Join-Path -Path $TestDrive -ChildPath 'probe-utf8.bin'
            $box = [string][char]0x2500
            $probeText = 'START-MARKER' + "`r`n" + `
                ([string][char]0x256D) + ($box * 30) + ([string][char]0x256E) + "`r`n" + `
                ([string][char]0x2502) + ' SALAM-MARKER ' + ([string][char]0x2502) + "`r`n" + `
                ([string][char]0x2570) + ($box * 30) + ([string][char]0x256F) + "`r`n" + `
                'END-MARKER'
            [System.IO.File]::WriteAllBytes($probePath, [System.Text.Encoding]::UTF8.GetBytes($probeText))

            # The scenario writes the file's RAW BYTES straight to the console
            # output handle (no WriteConsoleW) - byte-writer semantics.
            $scenarioPath = Join-Path -Path $TestDrive -ChildPath 'scenario-bytewriter.ps1'
            @'
$bytes = [System.IO.File]::ReadAllBytes($env:BsnSystemTestProbeFile)
$stdout = [Console]::OpenStandardOutput()
$stdout.Write($bytes, 0, $bytes.Length)
$stdout.Flush()
'@ | Set-Content -LiteralPath $scenarioPath -Encoding UTF8

            $env:BsnSystemTestProbeFile = $probePath
            try {
                $castPath = Join-Path -Path $TestDrive -ChildPath 'bytewriter.cast'
                $result = Invoke-BsnSystemRecording -ScenarioPath $scenarioPath -CastPath $castPath
                $result.ExitCode | Should -Be 0
            }
            finally {
                Remove-Item 'Env:BsnSystemTestProbeFile' -ErrorAction 'SilentlyContinue'
            }

            $rawStream = Get-BsnCastRawStream -CastPath $castPath
            $countOf = { param($codePoint) ([regex]::Matches($rawStream, [regex]::Escape([string][char]$codePoint))).Count }

            (& $countOf 0x256D) | Should -Be 1 -Because 'the top-left rounded corner must survive (mangling turns one box character into several CP-decoded characters)'
            (& $countOf 0x2500) | Should -Be 60 -Because 'all sixty horizontal border characters must survive byte-for-byte'
            (& $countOf 0x256E) | Should -Be 1 -Because 'the top-right rounded corner must survive'
            (& $countOf 0x2570) | Should -Be 1 -Because 'the bottom-left rounded corner must survive'
            (& $countOf 0x256F) | Should -Be 1 -Because 'the bottom-right rounded corner must survive'
            $rawStream.Contains('SALAM-MARKER') | Should -BeTrue -Because 'the ASCII payload must be captured'

            $replacementCount = ([regex]::Matches($rawStream, [regex]::Escape([string][char]0xFFFD))).Count
            $replacementCount | Should -Be 0 -Because 'no chunk-boundary U+FFFD corruption is allowed (issue #5 decoder fix)'
            $mojibakeCount = ([regex]::Matches($rawStream, '[\u00C0-\u00FF]')).Count
            $mojibakeCount | Should -Be 0 -Because ('no codepage-decoded mojibake characters are allowed; found {0} Latin-1-range characters, the signature of conhost decoding UTF-8 bytes with the OEM codepage (issue #5)' -f $mojibakeCount)
        }

        It 'records a real OpenCode TUI session without corruption' -Tag 'RequiresOpenCode' {
            # https://github.com/BSVN/Lmt.Commons/issues/5
            # The exact scenario from the field report: OpenCode renders its
            # full-screen TUI (Bubble Tea/Go) by writing UTF-8 bytes directly
            # to the console handle. On OEM-codepage-decoding conhosts this
            # corrupted every border in the recording.
            if (-not $script:CanRunSystemTests) {
                Set-ItResult -Skipped -Because 'pwsh is required to run recorded scenarios and was not found.'
            }
            if ($PSVersionTable.PSVersion.Major -lt 7) {
                Set-ItResult -Skipped -Because 'system tests require PowerShell 7 console infrastructure.'
            }
            if (-not $script:IsWindowsPlatform) {
                Set-ItResult -Skipped -Because 'OpenCode TUI recording test targets the Windows ConPTY engine.'
            }
            if (-not (Get-Command -Name 'opencode' -ErrorAction 'SilentlyContinue')) {
                Set-ItResult -Skipped -Because 'opencode is not on PATH (install it to run this real-world TUI regression test).'
            }

            $scenarioPath = Join-Path -Path $TestDrive -ChildPath 'scenario-opencode.ps1'
            @'
$env:TERM = 'xterm-256color'
opencode
'@ | Set-Content -LiteralPath $scenarioPath -Encoding UTF8

            $castPath = Join-Path -Path $TestDrive -ChildPath 'opencode.cast'
            $null = Invoke-BsnSystemRecording -ScenarioPath $scenarioPath -CastPath $castPath -StopAfterDelay
            Test-Path -LiteralPath $castPath | Should -BeTrue -Because 'the OpenCode session must produce a cast'

            $rawStream = Get-BsnCastRawStream -CastPath $castPath
            $rawStream.Length | Should -BeGreaterThan 1000 -Because 'the OpenCode TUI renders substantial output'

            $replacementCount = ([regex]::Matches($rawStream, [regex]::Escape([string][char]0xFFFD))).Count
            $replacementCount | Should -Be 0 -Because 'the OpenCode TUI recording must contain zero U+FFFD replacement characters'
            $mojibakeCount = ([regex]::Matches($rawStream, '[\u00C0-\u00FF]')).Count
            $mojibakeCount | Should -Be 0 -Because ('the OpenCode TUI recording must contain zero codepage mojibake characters (found {0}); UTF-8 box-drawing borders must survive the console codepage bootstrap (issue #5)' -f $mojibakeCount)

            $hasKnownUiText = $rawStream.Contains('New session') -or $rawStream.Contains('Ask anything') -or $rawStream.Contains('Build')
            $hasKnownUiText | Should -BeTrue -Because 'the OpenCode UI text must be captured (proves the recorded session is the TUI)'
        }

        It 'keeps the LIVE proxied view clean on an OEM-codepage console (conlog)' -Tag 'RequiresConLog' {
            # https://github.com/BSVN/Lmt.Commons/issues/5
            # Field regression from the v0.2.2 rollout: the CAST was clean (all
            # capture tests pass) yet the user still watched mojibake during the
            # recording. Cause: the engine proxies the ConPTY stream to the REAL
            # console as raw UTF-8 bytes, and the console decodes those bytes
            # with its own OUTPUT codepage - OEM 437 in cmd, Windows PowerShell
            # 5.1 hosts and fresh hidden consoles. UTF-8 box borders became
            # CP437 soup ('Gamma-ohmega-acute') in the live view while every
            # cast-asserting test stayed green. This test reproduces that
            # topology: conlog wraps the runner in its own pseudoconsole, the
            # runner forces its console to the OEM codepage like the reporting
            # user's, and the capture shows exactly what that console rendered.
            if (-not $script:CanRunSystemTests) {
                Set-ItResult -Skipped -Because 'pwsh is required to run recorded scenarios and was not found.'
            }
            if ($PSVersionTable.PSVersion.Major -lt 7) {
                Set-ItResult -Skipped -Because 'system tests require PowerShell 7 console infrastructure.'
            }
            if (-not $script:IsWindowsPlatform) {
                Set-ItResult -Skipped -Because 'the live-view codepage test targets the Windows ConPTY engine.'
            }
            if (-not $script:HasConsoleLogger) {
                Set-ItResult -Skipped -Because 'conlog.exe is not on PATH (build from https://github.com/rhubarb-geek-nz/console-logger).'
            }

            # Probe: UTF-8 box border plus ASCII markers, written as RAW BYTES
            # to the console output handle by the recorded child - byte-writer
            # semantics, the shape every Go/Node TUI produces.
            $liveProbePath = Join-Path -Path $TestDrive -ChildPath 'liveview-probe.bin'
            $thinRule = [string][char]0x2500
            $liveProbeText = 'LIVE-HEAD' + "`r`n" +
                ([string][char]0x256D) + ($thinRule * 20) + ([string][char]0x256E) + "`r`n" +
                ([string][char]0x2502) + ' LIVE-MARKER ' + ([string][char]0x2502) + "`r`n" +
                ([string][char]0x2570) + ($thinRule * 20) + ([string][char]0x256F) + "`r`n" +
                'LIVE-TAIL'
            [System.IO.File]::WriteAllBytes($liveProbePath, [System.Text.Encoding]::UTF8.GetBytes($liveProbeText))

            $liveScenarioPath = Join-Path -Path $TestDrive -ChildPath 'liveview-child.ps1'
            @'
$payload = [System.IO.File]::ReadAllBytes($env:BsnLiveViewProbeFile)
$sink = [Console]::OpenStandardOutput()
$sink.Write($payload, 0, $payload.Length)
$sink.Flush()
'@ | Set-Content -LiteralPath $liveScenarioPath -Encoding UTF8

            $env:BsnLiveViewProbeFile = $liveProbePath
            try {
                # The runner executes INSIDE the conlog pseudoconsole (so its
                # stdio are console handles and in-process recording works -
                # same reason the hidden-console runner exists for CI), forces
                # its console output codepage to OEM 437 like the reporting
                # user's, records the byte-writing child, and reports the
                # console codepage from before and after the recording: the
                # engine must put it back.
                $liveRunnerPath = Join-Path -Path $TestDrive -ChildPath 'liveview-runner.ps1'
                $liveResultPath = Join-Path -Path $TestDrive -ChildPath 'liveview-result.json'
                $liveCastPath = Join-Path -Path $TestDrive -ChildPath 'liveview.cast'
                @"
param(`$RepoRoot, `$ScenarioPath, `$CastPath, `$ResultPath)
`$ErrorActionPreference = 'Stop'
chcp.com 437 | Out-Null
Import-Module (Join-Path `$RepoRoot 'src/Bsn.Common/Bsn.Common.psd1') -Force
Import-Module (Join-Path `$RepoRoot 'src/Bsn.Host/Bsn.Host.psd1') -Force
`$codePageBefore = ([regex]::Match((chcp.com | Out-String), '(\d+)')).Groups[1].Value
`$recording = Start-InteractiveTranscript -Command ('pwsh -NoProfile -File ' + `$ScenarioPath) -Path `$CastPath
`$codePageAfter = ([regex]::Match((chcp.com | Out-String), '(\d+)')).Groups[1].Value
@{ Exit = `$recording.ExitCode; CodePageBefore = `$codePageBefore; CodePageAfter = `$codePageAfter } |
    ConvertTo-Json | Set-Content -LiteralPath `$ResultPath
"@ | Set-Content -LiteralPath $liveRunnerPath -Encoding UTF8

                $liveCapturePath = Join-Path -Path $TestDrive -ChildPath 'liveview-capture.txt'
                $conlogCommand = Get-Command -Name 'conlog' -ErrorAction 'Stop'
                # Start-Process (not direct invocation) so conlog owns a fresh
                # hidden console: conlog reads its stdin as a console handle and
                # needs stdout OR stderr attached to a console device, which CI's
                # redirected stdio cannot provide (same trick as the
                # hidden-console recording runner). Only stdout is redirected to
                # the capture file - conlog's stdout IS the live view: what the
                # runner console actually rendered. stderr stays on the hidden
                # console (dropped).
                $conlogProcess = Start-Process -FilePath $conlogCommand.Source `
                    -ArgumentList @("pwsh -NoProfile -ExecutionPolicy Bypass -File $liveRunnerPath -RepoRoot $($script:RepoRoot) -ScenarioPath $liveScenarioPath -CastPath $liveCastPath -ResultPath $liveResultPath") `
                    -WindowStyle Hidden -RedirectStandardOutput $liveCapturePath -PassThru
                if (-not $conlogProcess.WaitForExit(120000)) {
                    $conlogProcess.Kill()
                    throw 'conlog live-view runner timed out after 120 seconds.'
                }
                if (-not (Test-Path -LiteralPath $liveResultPath)) {
                    throw ("conlog live-view runner produced no result (exit code {0}); capture: {1}" -f $conlogProcess.ExitCode, (Get-Content -LiteralPath $liveCapturePath -Raw))
                }

                $liveOutcome = Get-Content -LiteralPath $liveResultPath -Raw | ConvertFrom-Json
                $liveOutcome.Exit | Should -Be 0 -Because 'the recorded scenario must succeed'
                $liveOutcome.CodePageBefore | Should -Be '437' -Because 'the runner console must sit at the OEM codepage to reproduce the reported environment'
                $liveOutcome.CodePageAfter | Should -Be '437' -Because 'the engine must restore the original console codepage after the recording (issue #5 live view)'

                $liveStream = Get-Content -LiteralPath $liveCapturePath -Raw
                $liveStream.Contains('LIVE-MARKER') | Should -BeTrue -Because 'the proxied live view must carry the payload text'

                $liveGlyphCount = { param($codePoint) ([regex]::Matches($liveStream, [regex]::Escape([string][char]$codePoint))).Count }
                (& $liveGlyphCount 0x256D) | Should -Be 1 -Because 'the live view must render the rounded corner itself, not its CP437-decoded byte soup'
                (& $liveGlyphCount 0x2500) | Should -Be 40 -Because 'both border rows must survive into the live view'

                # CP437-decoded UTF-8 shows up as Latin-1-range letters plus Greek
                # Gamma (0xE2 is 'Gamma' in CP437, the lead byte of every 3-byte
                # UTF-8 sequence) - none of that may appear in the live view.
                $liveMojibake = ([regex]::Matches($liveStream, '[\u00C0-\u00FF\u0393]')).Count
                $liveMojibake | Should -Be 0 -Because ('the live proxied view must be free of codepage mojibake on an OEM-codepage console (found {0}); the console decodes the recorder''s raw UTF-8 bytes with its output codepage (issue #5 live view)' -f $liveMojibake)
            }
            finally {
                Remove-Item 'Env:BsnLiveViewProbeFile' -ErrorAction 'SilentlyContinue'
            }
        }

        It 'keeps PLAYBACK lossless on an OEM-codepage console in Windows PowerShell 5.1 (conlog)' {
            # https://github.com/BSVN/Lmt.Commons/issues/5
            # Second half of the viewer bug: Show-InteractiveTranscript in
            # Windows PowerShell 5.1 writes [Console] output through the
            # console output CODEPAGE (WriteFile), so heavy box characters
            # (U+2503, U+2579, U+256D - none exist in CP437) degraded to
            # literal '?' in the playback while ASCII and CP437 blocks
            # survived - exactly the reported OpenCode viewer screenshot.
            # The playback must switch the console output encoding to UTF-8
            # for its duration and restore it. This test plays a real
            # recording back through powershell.exe 5.1 inside a conlog
            # pseudoconsole forced to the OEM codepage: the capture is what
            # that console rendered.
            if (-not $script:CanRunSystemTests) {
                Set-ItResult -Skipped -Because 'pwsh is required to run recorded scenarios and was not found.'
            }
            if (-not $script:IsWindowsPlatform) {
                Set-ItResult -Skipped -Because 'the playback codepage test targets the Windows ConPTY engine.'
            }
            if (-not $script:HasConsoleLogger) {
                Set-ItResult -Skipped -Because 'conlog.exe is not on PATH (build from https://github.com/rhubarb-geek-nz/console-logger).'
            }

            # Record a cast that contains corner characters (not in CP437):
            # the byte-writing probe child makes the recording deterministic.
            $probePath = Join-Path -Path $TestDrive -ChildPath 'playback-probe.bin'
            $rule = [string][char]0x2500
            $probeText = 'PB-HEAD' + "`r`n" +
                ([string][char]0x256D) + ($rule * 18) + ([string][char]0x256E) + "`r`n" +
                ([string][char]0x2502) + ' PB-MARKER ' + ([string][char]0x2502) + "`r`n" +
                ([string][char]0x2570) + ($rule * 18) + ([string][char]0x256F) + "`r`n" +
                'PB-TAIL'
            [System.IO.File]::WriteAllBytes($probePath, [System.Text.Encoding]::UTF8.GetBytes($probeText))

            $childPath = Join-Path -Path $TestDrive -ChildPath 'playback-child.ps1'
            @'
$payload = [System.IO.File]::ReadAllBytes($env:BsnPlaybackProbeFile)
$sink = [Console]::OpenStandardOutput()
$sink.Write($payload, 0, $payload.Length)
$sink.Flush()
'@ | Set-Content -LiteralPath $childPath -Encoding UTF8

            $env:BsnPlaybackProbeFile = $probePath
            try {
                $castPath = Join-Path -Path $TestDrive -ChildPath 'playback.cast'
                $null = Invoke-BsnSystemRecording -ScenarioPath $childPath -CastPath $castPath

                # Play the cast back through powershell.exe 5.1 inside a conlog
                # pseudoconsole whose console sits at the OEM codepage: conlog's
                # capture is the rendered playback, exactly what the reporting
                # user's viewer showed.
                $playRunnerPath = Join-Path -Path $TestDrive -ChildPath 'playback-runner51.ps1'
                $playResultPath = Join-Path -Path $TestDrive -ChildPath 'playback-result.json'
                @"
param(`$RepoRoot, `$CastPath, `$ResultPath)
`$ErrorActionPreference = 'Stop'
chcp.com 437 | Out-Null
Import-Module (Join-Path `$RepoRoot 'src/Bsn.Common/Bsn.Common.psd1') -Force
Import-Module (Join-Path `$RepoRoot 'src/Bsn.Host/Bsn.Host.psd1') -Force
`$codePageBefore = ([regex]::Match((chcp.com | Out-String), '(\d+)')).Groups[1].Value
Show-InteractiveTranscript -Path `$CastPath
`$codePageAfter = ([regex]::Match((chcp.com | Out-String), '(\d+)')).Groups[1].Value
@{ Before = `$codePageBefore; After = `$codePageAfter } | ConvertTo-Json | Set-Content -LiteralPath `$ResultPath
"@ | Set-Content -LiteralPath $playRunnerPath -Encoding UTF8

                $playCapturePath = Join-Path -Path $TestDrive -ChildPath 'playback-capture.txt'
                $conlogCommand = Get-Command -Name 'conlog' -ErrorAction 'Stop'
                $conlogProcess = Start-Process -FilePath $conlogCommand.Source `
                    -ArgumentList @("powershell.exe -NoProfile -ExecutionPolicy Bypass -File $playRunnerPath -RepoRoot $($script:RepoRoot) -CastPath $castPath -ResultPath $playResultPath") `
                    -WindowStyle Hidden -RedirectStandardOutput $playCapturePath -PassThru
                if (-not $conlogProcess.WaitForExit(120000)) {
                    $conlogProcess.Kill()
                    throw 'conlog playback runner timed out after 120 seconds.'
                }
                if (-not (Test-Path -LiteralPath $playResultPath)) {
                    throw ("conlog playback runner produced no result (exit code {0}); capture: {1}" -f $conlogProcess.ExitCode, (Get-Content -LiteralPath $playCapturePath -Raw))
                }

                $playOutcome = Get-Content -LiteralPath $playResultPath -Raw | ConvertFrom-Json
                $playOutcome.Before | Should -Be '437' -Because 'the playback console must sit at the OEM codepage to reproduce the reported viewer'
                $playOutcome.After | Should -Be '437' -Because 'the playback must restore the console output encoding it found (issue #5 viewer bug)'

                $playStream = Get-Content -LiteralPath $playCapturePath -Raw
                $playStream.Contains('PB-MARKER') | Should -BeTrue -Because 'the playback must carry the payload text'

                $playGlyphCount = { param($codePoint) ([regex]::Matches($playStream, [regex]::Escape([string][char]$codePoint))).Count }
                (& $playGlyphCount 0x256D) | Should -Be 1 -Because 'the corner must render in the playback, not degrade to a question mark (issue #5 viewer bug)'
                (& $playGlyphCount 0x2500) | Should -Be 36 -Because 'both border rows must survive playback'

                # Count RENDERED question marks: strip VT sequences first (the
                # passthrough stream legitimately contains '?' inside CSI
                # private-mode sequences like ESC[?25l - those are interpreted,
                # never rendered).
                $plainPlayback = Convert-BsnCastPlainText -RawStream $playStream
                $playQuestionMarks = ([regex]::Matches($plainPlayback, '\?')).Count
                $playQuestionMarks | Should -Be 0 -Because ('CP437-unrepresentable characters must not degrade to literal question marks during playback (found {0}; issue #5 viewer bug)' -f $playQuestionMarks)
            }
            finally {
                Remove-Item 'Env:BsnPlaybackProbeFile' -ErrorAction 'SilentlyContinue'
            }
        }
    }

    Context 'Issue #7: metacharacters survive a REAL ConPTY recording' {
        # https://github.com/BSVN/Lmt.Commons/issues/7
        # The unit tests prove -EncodedCommand preserves the command text; this
        # system test proves it END TO END through the real engine: the recorded
        # output must contain the metacharacter payload verbatim.
        It 'records -Command values with pipes, ampersands and redirections exactly' {
            if (-not $script:CanRunSystemTests) {
                Set-ItResult -Skipped -Because 'pwsh is required to run recorded scenarios and was not found.'
            }
            if ($PSVersionTable.PSVersion.Major -lt 7) {
                Set-ItResult -Skipped -Because 'system tests require PowerShell 7 console infrastructure.'
            }
            if (-not $script:IsWindowsPlatform -and ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected)) {
                Set-ItResult -Skipped -Because 'the Unix script(1) engine is unreliable under CI redirected stdio; run locally.'
            }

            $scenarioPath = Join-Path -Path $TestDrive -ChildPath 'scenario-metachar.ps1'
            @'
Write-Output 'METACHAR:a|b&c<d>e^f'
'@ | Set-Content -LiteralPath $scenarioPath -Encoding UTF8

            $castPath = Join-Path -Path $TestDrive -ChildPath 'metachar.cast'
            $result = Invoke-BsnSystemRecording -ScenarioPath $scenarioPath -CastPath $castPath
            $result.ExitCode | Should -Be 0

            $rawStream = Get-BsnCastRawStream -CastPath $castPath
            $rawStream.Contains('METACHAR:a|b&c<d>e^f') | Should -BeTrue -Because 'pipes, ampersands, redirections and carets must survive the recorded command line verbatim (issue #7)'
        }
    }

    Context 'Issue #20: response-eliciting query sequences are filtered out of the cast at capture time' {
        # https://github.com/BSVN/Lmt.Commons/issues/20
        # Root cause: recorded TUIs (OpenCode/termenv, lipgloss, ncurses)
        # emit QUERY sequences as part of their output stream - XTWINOPS
        # pixel-size requests (ESC[14t, the exact artifact behind the
        # reported '[4;600;1200t' at the prompt), DSR cursor-position
        # requests (ESC[6n), DA queries, kitty keyboard protocol queries
        # (ESC[?u), XTVERSION (ESC[>0q), OSC default-color queries. Those
        # queries are only meaningful while the ORIGINAL application is
        # connected: a cast that contains them makes ANY player re-broadcast
        # them, the real terminal answers into the console input buffer, and
        # PSReadLine consumes the answers as typed text at the prompt.
        # Root-cause fix: the recorder filters response-eliciting sequences
        # out of the cast at CAPTURE time (CastWriter/TerminalQueryFilter) -
        # casts never contain queries, so playback of ours or any other
        # player is clean by construction.

        It 'filters query sequences out of a recorded BYTE-WRITING child cast' {
            if (-not $script:CanRunSystemTests) {
                Set-ItResult -Skipped -Because 'pwsh is required to run recorded scenarios and was not found.'
            }
            if ($PSVersionTable.PSVersion.Major -lt 7) {
                Set-ItResult -Skipped -Because 'system tests require PowerShell 7 console infrastructure.'
            }
            if (-not $script:IsWindowsPlatform) {
                Set-ItResult -Skipped -Because 'the query filtering is a ConPTY engine (Windows) behavior.'
            }

            # The probe file holds UTF-8 bytes for box-drawing borders, an
            # ASCII marker AND the query families from the issue - exactly
            # the payload shape of a byte-writing TUI (Go/Node raw writes).
            $probePath = Join-Path -Path $TestDrive -ChildPath 'probe-utf8.bin'
            $esc = [string][char]27
            $bel = [string][char]7
            $box = [string][char]0x2500
            $probeText = 'START-MARKER' + "`r`n" + `
                "$esc[14t" + "$esc[6n" + "$esc[?u" + "$esc[>0q" + "$esc]11;?$bel" + `
                ([string][char]0x256D) + ($box * 30) + ([string][char]0x256E) + "`r`n" + `
                ([string][char]0x2502) + ' SALAM-MARKER ' + ([string][char]0x2502) + "`r`n" + `
                ([string][char]0x2570) + ($box * 30) + ([string][char]0x256F) + "`r`n" + `
                'END-MARKER'
            [System.IO.File]::WriteAllBytes($probePath, [System.Text.Encoding]::UTF8.GetBytes($probeText))

            # The scenario writes the file's RAW BYTES straight to the console
            # output handle (no WriteConsoleW) - byte-writer semantics.
            $scenarioPath = Join-Path -Path $TestDrive -ChildPath 'scenario-bytewriter.ps1'
            @'
$bytes = [System.IO.File]::ReadAllBytes($env:BsnSystemTestProbeFile)
$stdout = [Console]::OpenStandardOutput()
$stdout.Write($bytes, 0, $bytes.Length)
$stdout.Flush()
'@ | Set-Content -LiteralPath $scenarioPath -Encoding UTF8

            $env:BsnSystemTestProbeFile = $probePath
            try {
                $castPath = Join-Path -Path $TestDrive -ChildPath 'bytewriter.cast'
                $result = Invoke-BsnSystemRecording -ScenarioPath $scenarioPath -CastPath $castPath
                $result.ExitCode | Should -Be 0
            }
            finally {
                Remove-Item 'Env:BsnSystemTestProbeFile' -ErrorAction 'SilentlyContinue'
            }

            $castText = [System.IO.File]::ReadAllText($castPath, [System.Text.Encoding]::UTF8)

            # The payload must survive.
            $castText.Contains('SALAM-MARKER') | Should -BeTrue -Because 'the ASCII payload must be captured'
            ([regex]::Matches($castText, [regex]::Escape($box))).Count | Should -Be 60 -Because 'all sixty horizontal border characters must survive'
            ([regex]::Matches($castText, [regex]::Escape([string][char]0x256D))).Count | Should -Be 1 -Because 'the top-left rounded corner must survive'
            ([regex]::Matches($castText, [regex]::Escape([string][char]0x256F))).Count | Should -Be 1 -Because 'the bottom-right rounded corner must survive'

            # The queries must NOT be in the cast (stored JSON-escaped: ESC is \u001b).
            foreach ($escapedQuery in @('\u001b[14t', '\u001b[6n', '\u001b[?u', '\u001b[>0q', '\u001b]11;?', '\u001b]10;?')) {
                $castText.Contains($escapedQuery) | Should -BeFalse -Because ("the cast must not contain the query sequence {0} - playback would elicit a terminal response into the console input buffer (issue #20)" -f $escapedQuery)
            }

            # Filtering must not introduce corruption of its own.
            ([regex]::Matches($castText, [regex]::Escape([string][char]0xFFFD))).Count | Should -Be 0 -Because 'the filter must not create U+FFFD replacement characters'
        }

        It 'playback of a recorded session leaves the console input buffer clean' {
            if (-not $script:CanRunSystemTests) {
                Set-ItResult -Skipped -Because 'pwsh is required to run recorded scenarios and was not found.'
            }
            if ($PSVersionTable.PSVersion.Major -lt 7) {
                Set-ItResult -Skipped -Because 'system tests require PowerShell 7 console infrastructure.'
            }
            if (-not $script:IsWindowsPlatform) {
                Set-ItResult -Skipped -Because 'the console input buffer is a Windows (ConPTY/conhost) concept.'
            }

            # Record the byte-writing child (query bytes in its output), then
            # play the resulting cast back: with queries filtered at capture
            # time the terminal has nothing to answer into the input buffer.
            $probePath = Join-Path -Path $TestDrive -ChildPath 'probe-utf8.bin'
            $esc = [string][char]27
            $bel = [string][char]7
            $probeText = "$esc[14t$esc[6n" + "$esc]11;?$bel" + 'END-MARKER'
            [System.IO.File]::WriteAllBytes($probePath, [System.Text.Encoding]::UTF8.GetBytes($probeText))

            $scenarioPath = Join-Path -Path $TestDrive -ChildPath 'scenario-bytewriter2.ps1'
            @'
$bytes = [System.IO.File]::ReadAllBytes($env:BsnSystemTestProbeFile)
$stdout = [Console]::OpenStandardOutput()
$stdout.Write($bytes, 0, $bytes.Length)
$stdout.Flush()
'@ | Set-Content -LiteralPath $scenarioPath -Encoding UTF8

            $env:BsnSystemTestProbeFile = $probePath
            try {
                $castPath = Join-Path -Path $TestDrive -ChildPath 'playback-clean.cast'
                $result = Invoke-BsnSystemRecording -ScenarioPath $scenarioPath -CastPath $castPath
                $result.ExitCode | Should -Be 0
            }
            finally {
                Remove-Item 'Env:BsnSystemTestProbeFile' -ErrorAction 'SilentlyContinue'
            }

            $probe = Invoke-BsnPlaybackInputBufferProbe -CastPath $castPath
            $probe.After | Should -Be 0 -Because ('playback must not leave terminal query responses in the console input buffer where PSReadLine would show them as typed text (the reported [4;600;1200t artifact, issue #20); input records after playback: {0}' -f $probe.After)
        }
    }

    Context 'session with cmdlets and a TUI application' {
        It 'records the session and the cast matches the real view' {
            if (-not $script:CanRunSystemTests) {
                Set-ItResult -Skipped -Because 'pwsh is required to run recorded scenarios and was not found.'
            }
            if ($PSVersionTable.PSVersion.Major -lt 7) {
                Set-ItResult -Skipped -Because 'system tests require PowerShell 7 console infrastructure; the ConPTY hidden-console proxy behaves differently on Windows PowerShell 5.1.'
            }
            if (-not $script:IsWindowsPlatform -and ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected)) {
                Set-ItResult -Skipped -Because 'the Unix script(1) engine uses ProcessStartInfo.Arguments which is unreliable under CI redirected stdio; run locally in a terminal, or fix the engine to use ArgumentList (follow-up).'
            }
            $castPath = Join-Path -Path $TestDrive -ChildPath 'session-system.cast'
            $scenarioPath = Get-BsnScenarioScript -Directory $TestDrive

            $result = Invoke-BsnSystemRecording -ScenarioPath $scenarioPath -CastPath $castPath

            # Recording summary is healthy
            $result.ExitCode | Should -Be 0 -Because 'the scenario script must succeed'
            $result.StoppedByRequest | Should -BeFalse -Because 'command-scoped recordings end when the command exits'
            Test-Path -LiteralPath $castPath | Should -BeTrue

            # The cast is well-formed
            $timeline = & $script:HostModule { param($p) Get-BsnCastTimeline -Path $p } $castPath
            $timeline.Header.version | Should -BeIn @(2, 3)
            @($timeline.Events).Count | Should -BeGreaterThan 2

            # Reconstruct the view: raw stream (what the terminal received)
            # and its plain-text rendering (what a user would have seen).
            $rawStream = Get-BsnCastRawStream -CastPath $castPath
            $plainView = Convert-BsnCastPlainText -RawStream $rawStream

            # TUI capture: alternate-screen enter/exit sequences are recorded
            $esc = [char]27
            $rawStream.Contains($esc + '[?1049h') | Should -BeTrue -Because 'the TUI simulation must be captured with its alternate-screen enter sequence'
            $rawStream.Contains($esc + '[?1049l') | Should -BeTrue -Because 'the TUI simulation must be captured with its alternate-screen exit sequence'

            # The rendered view shows every phase of the session, in order
            $indexOfStart = $plainView.IndexOf('SYSMARK-A: recorded session start')
            $indexOfPid = $plainView.IndexOf('SYSMARK-PID: ')
            $indexOfTui = $plainView.IndexOf('TUI-FRAME: simulated full-screen application')
            $indexOfEnd = $plainView.IndexOf('SYSMARK-B: after TUI exit')

            $indexOfStart | Should -BeGreaterThan (-1) -Because 'the first marker must be visible in the cast'
            $indexOfPid | Should -BeGreaterThan $indexOfStart -Because 'cmdlet output must follow the start marker'
            $indexOfTui | Should -BeGreaterThan $indexOfPid -Because 'the TUI frame must follow the cmdlet output'
            $indexOfEnd | Should -BeGreaterThan $indexOfTui -Because 'the post-TUI marker must follow the TUI frame'

            # No keystroke events: input recording is off by default.
            @($timeline.Events | Where-Object -FilterScript { $_[1] -eq 'i' }).Count | Should -Be 0
        }
    }

    Context 'Unix script(1) engine: -Command recording (util-linux 2.41 regression)' {
        It 'records a -Command session and captures the markers on Linux/macOS' -Tag 'SystemTest' {
            # Regression for Ubuntu 26.04 / util-linux 2.41: util-linux rejects
            # combining --log-out with a trailing positional typescript file
            # ('unexpected number of arguments'), which made every -Command
            # recording come back empty (0 events). The invocation must use the
            # options-only form. Runs under CI redirected stdio on purpose:
            # script(1) allocates its own PTY, and -Command children like
            # 'echo' do not need stdin, so this is deterministic in CI.
            if (-not $script:CanRunSystemTests) {
                Set-ItResult -Skipped -Because 'pwsh is required to run recorded scenarios and was not found.'
            }
            if ($PSVersionTable.PSVersion.Major -lt 7) {
                Set-ItResult -Skipped -Because 'system tests require PowerShell 7 console infrastructure.'
            }
            if ($script:IsWindowsPlatform) {
                Set-ItResult -Skipped -Because 'Windows uses the ConPTY engine; this regression targets the Unix script(1) engine.'
            }

            $marker = 'UNIXMARKER-{0}' -f (Get-Random)
            $castPath = Join-Path -Path $TestDrive -ChildPath 'unix-command.cast'
            $result = Start-InteractiveTranscript -Command ("echo $marker; uname -s") -Path $castPath

            $result.ExitCode | Should -Be 0 -Because 'the recorded echo command must succeed'
            $stream = Get-BsnCastRawStream -CastPath $castPath
            $stream.Length | Should -BeGreaterThan 0 -Because 'the recording must not be empty (util-linux 2.41 invocation regression)'
            $stream.Contains($marker) | Should -BeTrue -Because 'the recorded marker must be captured'
            $stream.Contains('Linux') -or $stream.Contains('Darwin') | Should -BeTrue -Because 'the uname -s output must be captured'
            $replacementCount = ([regex]::Matches($stream, [regex]::Escape([string][char]0xFFFD))).Count
            $replacementCount | Should -Be 0 -Because 'the recording must contain zero U+FFFD replacement characters'
        }
    }

    Context 'Stop-InteractiveTranscript finalizes a running session' {
        It 'stops early via the stop channel and captures everything before the stop' {
            if (-not $script:CanRunSystemTests) {
                Set-ItResult -Skipped -Because 'pwsh is required to run recorded scenarios and was not found.'
            }
            if ($PSVersionTable.PSVersion.Major -lt 7) {
                Set-ItResult -Skipped -Because 'system tests require PowerShell 7 console infrastructure; the ConPTY hidden-console proxy behaves differently on Windows PowerShell 5.1.'
            }
            if (-not $script:IsWindowsPlatform -and ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected)) {
                Set-ItResult -Skipped -Because 'the Unix script(1) engine uses ProcessStartInfo.Arguments which is unreliable under CI redirected stdio; run locally in a terminal, or fix the engine to use ArgumentList (follow-up).'
            }
            if (-not (Get-Command -Name 'Start-ThreadJob' -ErrorAction 'SilentlyContinue')) {
                Set-ItResult -Skipped -Because 'Start-ThreadJob is required for the in-session stop signal.'
            }

            $castPath = Join-Path -Path $TestDrive -ChildPath 'session-stop.cast'
            $scenarioPath = Get-BsnScenarioScript -Directory $TestDrive -WithLongSleep

            $result = Invoke-BsnSystemRecording -ScenarioPath $scenarioPath -CastPath $castPath -StopAfterDelay

            # The recording was stopped by request, long before the 120s sleep finished
            $result.StoppedByRequest | Should -BeTrue
            $result.DurationSec | Should -BeLessThan 60 -Because ('the session must be finalized by the stop signal, not the 120 second sleep (took {0}s)' -f $result.DurationSec)

            # Everything before the stop is in the cast ...
            $plainView = Convert-BsnCastPlainText -RawStream (Get-BsnCastRawStream -CastPath $castPath)
            $plainView.IndexOf('SYSMARK-A: recorded session start') | Should -BeGreaterThan (-1)
            $plainView.IndexOf('TUI-FRAME: simulated full-screen application') | Should -BeGreaterThan 0

            # ... and nothing that only happens after the sleep.
            $plainView.IndexOf('SYSMARK-B: after TUI exit') | Should -Be (-1) -Because 'content produced after the stop signal must not be recorded'
        }
    }
}
