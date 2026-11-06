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
    $script:IsWindowsPlatform = ($PSVersionTable.PSVersion.Major -ge 6) -and ($PSVersionTable.ContainsKey('Platform') -and ($PSVersionTable['Platform'] -eq 'Win32NT') -or $env:OS -eq 'Windows_NT')
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
