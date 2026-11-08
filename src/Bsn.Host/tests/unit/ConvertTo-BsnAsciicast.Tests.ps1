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
}

Describe 'ConvertTo-BsnAsciicast' {
    Context 'timing-exact conversion (util-linux script logs)' {
        BeforeAll {
            $script:OutputPath = Join-Path -Path $TestDrive -ChildPath 'output.log'
            $script:TimingPath = Join-Path -Path $TestDrive -ChildPath 'timing.log'
            $script:CastPath = Join-Path -Path $TestDrive -ChildPath 'session.cast'

            [System.IO.File]::WriteAllBytes($OutputPath, [System.Text.Encoding]::UTF8.GetBytes('helloworld!'))
            Set-Content -LiteralPath $TimingPath -Value "+0.1 5`n+0.25 6" -NoNewline

            & (Get-Module -Name 'Bsn.Host') { param($o, $t, $c) ConvertTo-BsnAsciicast -OutputPath $o -TimingPath $t -CastPath $c -Width 100 -Height 40 } $OutputPath $TimingPath $CastPath

            $script:CastLines = Get-Content -LiteralPath $CastPath
        }

        It 'writes the asciicast v2 header with the requested size' {
            $header = $CastLines[0] | ConvertFrom-Json
            $header.version | Should -Be 2
            $header.width | Should -Be 100
            $header.height | Should -Be 40
            $header.timestamp | Should -BeGreaterThan 0
        }

        It 'emits timing-exact output events' {
            $events = @($CastLines | Select-Object -Skip 1 | ForEach-Object -Process { , ($_ | ConvertFrom-Json) })
            $events.Count | Should -Be 2
            $events[0][0] | Should -Be 0.1
            $events[0][1] | Should -Be 'o'
            $events[0][2] | Should -Be 'hello'
            $events[1][0] | Should -Be 0.35
            $events[1][2] | Should -Be 'world!'
        }

        It 'round-trips special characters through JSON escaping' {
            $specialOutputPath = Join-Path -Path $TestDrive -ChildPath 'special.log'
            $specialTimingPath = Join-Path -Path $TestDrive -ChildPath 'special.timing'
            $specialCastPath = Join-Path -Path $TestDrive -ChildPath 'special.cast'

            $expectedText = 'say "hi"' + [char]10 + [char]9 + 'done'
            [System.IO.File]::WriteAllBytes($specialOutputPath, [System.Text.Encoding]::UTF8.GetBytes($expectedText))
            Set-Content -LiteralPath $specialTimingPath -Value '+0.5 14' -NoNewline

            & (Get-Module -Name 'Bsn.Host') { param($o, $t, $c) ConvertTo-BsnAsciicast -OutputPath $o -TimingPath $t -CastPath $c } $specialOutputPath $specialTimingPath $specialCastPath

            $castEvent = (Get-Content -LiteralPath $specialCastPath | Select-Object -Skip 1 -First 1) | ConvertFrom-Json
            $castEvent[2] | Should -Be $expectedText
        }
    }

    Context 'approximated conversion (BSD script logs)' {
        It 'spreads line events across the measured duration' {
            $outputPath = Join-Path -Path $TestDrive -ChildPath 'lines.log'
            $castPath = Join-Path -Path $TestDrive -ChildPath 'lines.cast'

            [System.IO.File]::WriteAllBytes($outputPath, [System.Text.Encoding]::UTF8.GetBytes("alpha`nbeta`ngamma`n"))

            & (Get-Module -Name 'Bsn.Host') { param($o, $c) ConvertTo-BsnAsciicast -OutputPath $o -CastPath $c -DurationSec 2.0 } $outputPath $castPath

            $events = @(Get-Content -LiteralPath $castPath | Select-Object -Skip 1 | ForEach-Object -Process { , ($_ | ConvertFrom-Json) })
            $events.Count | Should -Be 3
            $events[0][0] | Should -Be 0
            $events[1][0] | Should -Be 1
            $events[2][0] | Should -Be 2
            $events[0][2] | Should -Be ("alpha" + [char]10)
            $events[2][2] | Should -Be ("gamma" + [char]10)
        }
    }

    Context 'asciicast v3 conversion (interval-based events)' {
        It 'writes the v3 header, delta intervals and the x exit event' {
            $outputPath = Join-Path -Path $TestDrive -ChildPath 'v3.log'
            $timingPath = Join-Path -Path $TestDrive -ChildPath 'v3.timing'
            $castPath = Join-Path -Path $TestDrive -ChildPath 'v3.cast'

            [System.IO.File]::WriteAllBytes($outputPath, [System.Text.Encoding]::UTF8.GetBytes('helloworld!'))
            Set-Content -LiteralPath $timingPath -Value "+0.1 5`n+0.25 6" -NoNewline

            & (Get-Module -Name 'Bsn.Host') { param($o, $t, $c) ConvertTo-BsnAsciicast -OutputPath $o -TimingPath $t -CastPath $c -CastVersion 3 -ExitCode 7 -ShellName 'pwsh' } $outputPath $timingPath $castPath

            $castLines = Get-Content -LiteralPath $castPath
            $header = $castLines[0] | ConvertFrom-Json
            $header.version | Should -Be 3
            $header.term.cols | Should -Be 80
            $header.term.rows | Should -Be 24
            $header.term.type | Should -Be 'xterm-256color'
            $header.command | Should -Be 'pwsh'

            $events = @($castLines | Select-Object -Skip 1 | ForEach-Object -Process { , ($_ | ConvertFrom-Json) })
            $events.Count | Should -Be 3
            # v3 events carry intervals since the previous event, not absolute times.
            $events[0][0] | Should -Be 0.1
            $events[1][0] | Should -Be 0.25
            $events[2][1] | Should -Be 'x'
            $events[2][2] | Should -Be '7'
        }
    }

    Context 'file format' {
        It 'writes UTF-8 without BOM and LF line endings' {
            $outputPath = Join-Path -Path $TestDrive -ChildPath 'format.log'
            $timingPath = Join-Path -Path $TestDrive -ChildPath 'format.timing'
            $castPath = Join-Path -Path $TestDrive -ChildPath 'format.cast'

            [System.IO.File]::WriteAllBytes($outputPath, [System.Text.Encoding]::UTF8.GetBytes('x'))
            Set-Content -LiteralPath $timingPath -Value '+0 1' -NoNewline

            & (Get-Module -Name 'Bsn.Host') { param($o, $t, $c) ConvertTo-BsnAsciicast -OutputPath $o -TimingPath $t -CastPath $c } $outputPath $timingPath $castPath

            $castBytes = [System.IO.File]::ReadAllBytes($castPath)
            $castBytes[0] | Should -Not -Be 0xEF
            [System.Text.Encoding]::UTF8.GetString($castBytes).Contains("`r`n") | Should -BeFalse
        }
    }

    Context 'multi-byte UTF-8 survives chunk boundaries (issue #5)' {
        # https://github.com/BSVN/Lmt.Commons/issues/5
        It 'produces no U+FFFD when multi-byte chars span timing-file chunks' {
            $outputPath = Join-Path -Path $TestDrive -ChildPath 'utf8.log'
            $timingPath = Join-Path -Path $TestDrive -ChildPath 'utf8.timing'
            $castPath = Join-Path -Path $TestDrive -ChildPath 'utf8.cast'

            $blockElement = [char]0x2580
            $multiByteString = ($blockElement.ToString() * 100) + 'ASCII text between multi-byte runs ' + ($blockElement.ToString() * 100)
            $multiByteBytes = [System.Text.Encoding]::UTF8.GetBytes($multiByteString)

            $firstChunkLength = 151
            [System.IO.File]::WriteAllBytes($outputPath, $multiByteBytes)

            $timingContent = "+0.1 {0}`n+0.1 {1}" -f $firstChunkLength, ($multiByteBytes.Length - $firstChunkLength)
            Set-Content -LiteralPath $timingPath -Value $timingContent -NoNewline

            & (Get-Module -Name 'Bsn.Host') { param($o, $t, $c) ConvertTo-BsnAsciicast -OutputPath $o -TimingPath $t -CastPath $c } $outputPath $timingPath $castPath

            $castLines = Get-Content -LiteralPath $castPath | Select-Object -Skip 1
            foreach ($line in $castLines) {
                $castEvent = $line | ConvertFrom-Json
                $eventText = $castEvent[2]
                if ($eventText) {
                    $eventText.Contains([char]0xFFFD) | Should -BeFalse -Because "event must not contain U+FFFD replacement character"
                }
            }
        }
    }

    Context 'incremental flush prevents data loss (issue #6)' {
        # https://github.com/BSVN/Lmt.Commons/issues/6
        It 'the cast file has content immediately after the header is written' {
            $outputPath = Join-Path -Path $TestDrive -ChildPath 'flush.log'
            $castPath = Join-Path -Path $TestDrive -ChildPath 'flush.cast'
            Set-Content -LiteralPath $outputPath -Value 'hello' -NoNewline

            & (Get-Module -Name 'Bsn.Host') { param($o, $c) ConvertTo-BsnAsciicast -OutputPath $o -CastPath $c -DurationSec 1 } $outputPath $castPath

            $fileInfo = Get-Item -LiteralPath $castPath
            $fileInfo.Length | Should -BeGreaterThan 0
            $firstLine = Get-Content -LiteralPath $castPath -TotalCount 1
            $firstLine | Should -BeLike '*"version"*'
        }
    }

    Context 'query sequences are filtered out of converted casts (issue #20)' {
        # https://github.com/BSVN/Lmt.Commons/issues/20
        # Unix script(1) logs carry the same response-eliciting query bytes
        # from recorded children (XTWINOPS, DSR, OSC color queries). Casts
        # must not contain them: any player re-broadcasts them and the
        # terminal answers into the console input buffer.
        It 'filters query sequences from the timing-exact conversion while keeping the payload' {
            $esc = [string][char]27
            $bel = [string][char]7
            $box = [string][char]0x2500
            $outputPath = Join-Path -Path $TestDrive -ChildPath 'issue20.log'
            $timingPath = Join-Path -Path $TestDrive -ChildPath 'issue20.timing'
            $castPath = Join-Path -Path $TestDrive -ChildPath 'issue20.cast'

            $logText = 'START-MARKER' + "`r`n" + `
                "$esc[14t" + "$esc[6n" + "$esc[?u" + "$esc[>0q" + "$esc]11;?$bel" + `
                ([string][char]0x256D) + ($box * 30) + ([string][char]0x256E) + "`r`n" + `
                'END-MARKER'
            [System.IO.File]::WriteAllBytes($outputPath, [System.Text.Encoding]::UTF8.GetBytes($logText))

            # Two timing chunks that split the stream mid-way: the filter must
            # hold partial sequences across events.
            $total = [System.IO.File]::ReadAllBytes($outputPath).Length
            $firstChunk = 40
            "$firstChunk $firstChunk`n$($total - $firstChunk) $($total - $firstChunk)" |
                Set-Content -LiteralPath $timingPath -Encoding UTF8

            & (Get-Module -Name 'Bsn.Host') { param($o, $t, $c) ConvertTo-BsnAsciicast -OutputPath $o -TimingPath $t -CastPath $c } $outputPath $timingPath $castPath

            $castText = [System.IO.File]::ReadAllText($castPath, [System.Text.Encoding]::UTF8)

            # Payload survives.
            $castText.Contains('START-MARKER') | Should -BeTrue
            $castText.Contains('END-MARKER') | Should -BeTrue
            ([regex]::Matches($castText, [regex]::Escape($box))).Count | Should -Be 30

            # Queries are gone (stored JSON-escaped: ESC is \u001b).
            foreach ($escapedQuery in @('\u001b[14t', '\u001b[6n', '\u001b[?u', '\u001b[>0q', '\u001b]11;?')) {
                $castText.Contains($escapedQuery) | Should -BeFalse -Because ("converted casts must not contain the query sequence {0} (issue #20)" -f $escapedQuery)
            }

            # No new corruption introduced by the filter.
            ([regex]::Matches($castText, [regex]::Escape([string][char]0xFFFD))).Count | Should -Be 0
        }
    }
}
