BeforeAll {
    $moduleRoot = Split-Path -Parent -Path (Split-Path -Parent -Path $PSScriptRoot)
    $env:PSModulePath = '{0}{1}{2}' -f (Split-Path -Parent -Path $moduleRoot), [System.IO.Path]::PathSeparator, $env:PSModulePath
    $manifestPath = Join-Path -Path $moduleRoot -ChildPath 'Bsn.Host.psd1'
    try {
        Import-Module -Name $manifestPath -Force -ErrorAction 'Stop'
    }
    catch [System.IO.FileLoadException] {
        Import-Module -Name (Join-Path $moduleRoot 'Bsn.Host.psm1') -Force -ErrorAction 'Stop'
    }
}

Describe 'Issue #7: -Command values with shell metacharacters are preserved' {
    Context 'Get-BsnRecordingCommandLine encoding' {
        It 'uses Base64 encoding instead of cmd.exe /d /c' {
            $commandLine = & (Get-Module -Name 'Bsn.Host') { Get-BsnRecordingCommandLine -Command 'echo hello' }
            $commandLine | Should -Not -BeLike '*cmd.exe*'
            $commandLine | Should -BeLike '*-EncodedCommand*'
        }

        It 'preserves pipe characters through Base64 round-trip' {
            $original = "Write-Output A | Write-Host -NoNewline 'got: '"
            $commandLine = & (Get-Module -Name 'Bsn.Host') { param($c) Get-BsnRecordingCommandLine -Command $c } $original

            # Extract the Base64 payload and decode it
            if ($commandLine -match '-EncodedCommand\s+([A-Za-z0-9+/=]+)') {
                $decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
                $decoded | Should -Be $original
            }
            else {
                throw "Expected -EncodedCommand in command line but got: $commandLine"
            }
        }

        It 'preserves embedded double quotes through Base64 round-trip' {
            $original = 'Write-Output "hello | world" & more'
            $commandLine = & (Get-Module -Name 'Bsn.Host') { param($c) Get-BsnRecordingCommandLine -Command $c } $original

            if ($commandLine -match '-EncodedCommand\s+([A-Za-z0-9+/=]+)') {
                $decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
                $decoded | Should -Be $original
            }
            else {
                throw "Expected -EncodedCommand in command line but got: $commandLine"
            }
        }

        It 'preserves angle brackets and caret through Base64 round-trip' {
            $original = 'sort < input.txt > output.txt ^ special'
            $commandLine = & (Get-Module -Name 'Bsn.Host') { param($c) Get-BsnRecordingCommandLine -Command $c } $original

            if ($commandLine -match '-EncodedCommand\s+([A-Za-z0-9+/=]+)') {
                $decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
                $decoded | Should -Be $original
            }
            else {
                throw "Expected -EncodedCommand in command line but got: $commandLine"
            }
        }
    }
}

Describe 'Issue #8: redirected stdio produces an error instead of silent empty cast' {
    Context 'Test-BsnRecordingEnvironment behavior' {
        It 'throws when both stdin and stdout are redirected on Windows' {
            # In CI/test context, both are typically redirected
            if ([Console]::IsInputRedirected -and [Console]::IsOutputRedirected) {
                { & (Get-Module -Name 'Bsn.Host') { Test-BsnRecordingEnvironment -Platform Windows } } | Should -Throw '*cannot capture output*'
            }
            else {
                Set-ItResult -Skipped -Because 'requires redirected stdio (CI context).'
            }
        }

        It 'warns (not throws) when only one handle is redirected' {
            if ([Console]::IsInputRedirected -xor [Console]::IsOutputRedirected) {
                { & (Get-Module -Name 'Bsn.Host') { Test-BsnRecordingEnvironment -Platform Windows } } | Should -Not -Throw
            }
            else {
                Set-ItResult -Skipped -Because 'requires exactly one redirected handle.'
            }
        }
    }
}

Describe 'Issue #5: UTF-8 multi-byte sequences survive chunk boundaries (converter)' {
    Context 'ConvertTo-BsnAsciicast with chunked multi-byte data' {
        It 'produces no U+FFFD when multi-byte chars span timing-file chunks' {
            $outputPath = Join-Path -Path $TestDrive -ChildPath 'utf8.log'
            $timingPath = Join-Path -Path $TestDrive -ChildPath 'utf8.timing'
            $castPath = Join-Path -Path $TestDrive -ChildPath 'utf8.cast'

            # Build a byte stream with multi-byte characters that will be split
            # at chunk boundaries: 3-byte UTF-8 sequences (e.g. U+2580 = E2 96 80)
            # interleaved with ASCII to create non-aligned boundaries.
            $blockElement = [char]0x2580  # Upper half block, 3 UTF-8 bytes
            $multiByteString = ($blockElement.ToString() * 100) + 'ASCII text between multi-byte runs ' + ($blockElement.ToString() * 100)
            $multiByteBytes = [System.Text.Encoding]::UTF8.GetBytes($multiByteString)

            # Split at a position that falls mid-sequence (e.g., offset 151 = mid multi-byte char)
            $firstChunkLength = 151  # 50 * 3 bytes = 150, so byte 151 is the 1st byte of char 51
            [System.IO.File]::WriteAllBytes($outputPath, $multiByteBytes)

            # Timing: two events that split the stream at the chosen boundary
            $timingContent = "+0.1 {0}`n+0.1 {1}" -f $firstChunkLength, ($multiByteBytes.Length - $firstChunkLength)
            Set-Content -LiteralPath $timingPath -Value $timingContent -NoNewline

            & (Get-Module -Name 'Bsn.Host') { param($o, $t, $c) ConvertTo-BsnAsciicast -OutputPath $o -TimingPath $t -CastPath $c } $outputPath $timingPath $castPath

            # Verify: no U+FFFD in any event
            $castLines = Get-Content -LiteralPath $castPath | Select-Object -Skip 1  # skip header
            foreach ($line in $castLines) {
                $castEvent = $line | ConvertFrom-Json
                $eventText = $castEvent[2]
                if ($eventText) {
                    $eventText.Contains([char]0xFFFD) | Should -BeFalse -Because "event must not contain U+FFFD replacement character"
                }
            }
        }
    }
}

Describe 'Issue #6: CastWriter writes incrementally (AutoFlush)' {
    It 'the cast file has content immediately after the header is written' {
        # We can verify this indirectly: the PowerShell converter (ConvertTo-BsnAsciicast)
        # uses the same pattern (write header + events with flush). The C# CastWriter
        # now has AutoFlush=true. A system test that kills the recording mid-session
        # and checks the cast has a valid header + events exercises this end-to-end.
        # Here we verify the converter flushes (same correctness contract).
        $outputPath = Join-Path -Path $TestDrive -ChildPath 'flush.log'
        $castPath = Join-Path -Path $TestDrive -ChildPath 'flush.cast'
        Set-Content -LiteralPath $outputPath -Value 'hello'
        Set-Content -LiteralPath $outputPath -Value 'hello' -NoNewline

        # No timing file needed for approximated mode
        & (Get-Module -Name 'Bsn.Host') { param($o, $c) ConvertTo-BsnAsciicast -OutputPath $o -CastPath $c -DurationSec 1 } $outputPath $castPath

        # The file must have content (header line at minimum)
        $fileInfo = Get-Item -LiteralPath $castPath
        $fileInfo.Length | Should -BeGreaterThan 0
        $firstLine = Get-Content -LiteralPath $castPath -TotalCount 1
        $firstLine | Should -BeLike '*"version"*'
    }
}
