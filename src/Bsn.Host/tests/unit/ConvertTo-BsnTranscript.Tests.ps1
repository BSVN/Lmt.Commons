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

    $script:Separator = '*' * 22
    $script:EscapeCharacter = [string][char]27
    $script:BelCharacter = [string][char]7
    $script:EpochStart = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)

    # Expected Start/End time text, computed the same way the cmdlet derives
    # them from the cast header timestamp (invariant to the machine time zone).
    function Get-BsnExpectedTimeText {
        param([double]$Seconds)
        return $script:EpochStart.AddSeconds($Seconds).ToLocalTime().ToString('yyyyMMddHHmmss')
    }

    function Get-BsnTestCastHash {
        param([string]$CastPath)
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            return [System.BitConverter]::ToString($sha256.ComputeHash([System.IO.File]::ReadAllBytes($CastPath))).Replace('-', '').ToLowerInvariant()
        }
        finally {
            $sha256.Dispose()
        }
    }

    function Get-BsnExpectedTranscript {
        param(
            [string]$StartTimeText,
            [string]$EndTimeText,
            [string]$Username = '',
            [string]$RunAsUser = '',
            [string]$Machine = '',
            [string]$HostApplication = '',
            [string]$ProcessId = '',
            [string]$PSVersion = '',
            [string]$ExpectedPSEdition = '',
            [string[]]$BsnHeaderLines = @(),
            [string[]]$BodyLines = @(),
            [string]$StartedLine = ''
        )
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add($script:Separator)
        $lines.Add('PowerShell transcript start')
        $lines.Add('Start time: ' + $StartTimeText)
        $lines.Add('Username: ' + $Username)
        $lines.Add('RunAs User: ' + $RunAsUser)
        $lines.Add('Machine: ' + $Machine)
        $lines.Add('Host Application: ' + $HostApplication)
        $lines.Add('Process ID: ' + $ProcessId)
        $lines.Add('PSVersion: ' + $PSVersion)
        $lines.Add('PSEdition: ' + $ExpectedPSEdition)
        foreach ($bsnHeaderLine in $BsnHeaderLines) {
            $lines.Add($bsnHeaderLine)
        }
        $lines.Add($script:Separator)
        if ($StartedLine) {
            $lines.Add($StartedLine)
            $lines.Add('')
        }
        foreach ($bodyLine in $BodyLines) {
            $lines.Add($bodyLine)
        }
        $lines.Add($script:Separator)
        $lines.Add('PowerShell transcript end')
        $lines.Add('End time: ' + $EndTimeText)
        $lines.Add($script:Separator)
        return ([string]::Join("`r`n", $lines))
    }

    # A realistic v2 session: echoed command, SGR-colored output, and a
    # progress bar overtyped with carriage returns.
    $script:SessionCastPath = Join-Path -Path $TestDrive -ChildPath 'session.cast'
    Set-Content -LiteralPath $script:SessionCastPath -Value @'
{"version": 2, "width": 100, "height": 40, "timestamp": 1793895000, "title": "Bsn.Host interactive transcript", "env": {"SHELL": "pwsh", "TERM": "xterm-256color"}}
[0, "o", "PS C:\\> Get-Process\r\n"]
[0.5, "o", "\u001b[1;32mhandles  npm(k)\u001b[0m\r\n"]
[1, "o", "progress 10%\rprogress 50%\r100%\r\n"]
'@ -NoNewline

    $script:V3CastPath = Join-Path -Path $TestDrive -ChildPath 'v3.cast'
    Set-Content -LiteralPath $script:V3CastPath -Value @'
{"version": 3, "term": {"cols": 120, "rows": 30, "type": "xterm-256color"}, "timestamp": 1793895000, "command": "pwsh -NoProfile"}
[0.1, "o", "alpha\r\n"]
[0.15, "o", "beta\r\n"]
[0, "x", "7"]
'@ -NoNewline

    # An echo-free session (a hidden password read): the typed secret only
    # exists as an 'i' event.
    $script:AnnotatedCastPath = Join-Path -Path $TestDrive -ChildPath 'annotated.cast'
    Set-Content -LiteralPath $script:AnnotatedCastPath -Value @'
{"version": 2, "width": 80, "height": 24, "timestamp": 1793895000, "env": {"SHELL": "bash", "TERM": "xterm"}}
[0, "o", "Password: "]
[0.2, "i", "s3cr3t\r"]
[0.4, "i", "\u001b[A"]
[0.6, "o", "\r\n"]
'@ -NoNewline

    $script:HeaderOnlyCastPath = Join-Path -Path $TestDrive -ChildPath 'header-only.cast'
    Set-Content -LiteralPath $script:HeaderOnlyCastPath -Value @'
{"version": 2, "width": 80, "height": 24, "timestamp": 1793895000}
'@ -NoNewline

    # A cast with non-ASCII content, for encoding tests.
    $script:BoxRuleCastPath = Join-Path -Path $TestDrive -ChildPath 'boxrule.cast'
    Set-Content -LiteralPath $script:BoxRuleCastPath -Value @'
{"version": 2, "width": 80, "height": 24, "timestamp": 1793895000, "env": {"SHELL": "pwsh", "TERM": "xterm-256color"}}
[0, "o", "\u2500\u2500rule\r\n"]
'@ -NoNewline
}

Describe 'Remove-BsnTerminalSequence' {
    It 'strips CSI sequences (SGR, private modes, colon subparameters) and keeps the text' {
        $text = 'pre' + $script:EscapeCharacter + '[1;32mgreen' + $script:EscapeCharacter + '[0m' + $script:EscapeCharacter + '[?25h' + $script:EscapeCharacter + '[38:2::255:0:0m post'
        $result = & (Get-Module -Name 'Bsn.Host') { param($t) Remove-BsnTerminalSequence -Text $t } $text
        $result | Should -Be 'pregreen post'
    }

    It 'strips OSC strings terminated by BEL and by ST, keeping payload-adjacent text' {
        $text = 'a' + $script:EscapeCharacter + ']0;my title' + $script:BelCharacter + 'b' + $script:EscapeCharacter + ']8;;http://x' + $script:EscapeCharacter + '\link' + $script:EscapeCharacter + ']8;;' + $script:EscapeCharacter + '\c'
        $result = & (Get-Module -Name 'Bsn.Host') { param($t) Remove-BsnTerminalSequence -Text $t } $text
        $result | Should -Be 'ablinkc'
    }

    It 'strips truncated (unterminated) OSC strings to the end of the input' {
        $text = 'kept' + $script:EscapeCharacter + ']83;?ANSYS-unterminated'
        $result = & (Get-Module -Name 'Bsn.Host') { param($t) Remove-BsnTerminalSequence -Text $t } $text
        $result | Should -Be 'kept'
    }

    It 'strips two- and three-byte escape sequences (charset, keypad, cursor save/restore)' {
        $text = $script:EscapeCharacter + '(B' + $script:EscapeCharacter + '=plain' + $script:EscapeCharacter + '7' + $script:EscapeCharacter + '8 text'
        $result = & (Get-Module -Name 'Bsn.Host') { param($t) Remove-BsnTerminalSequence -Text $t } $text
        $result | Should -Be 'plain text'
    }

    It 'strips DCS strings' {
        $text = 'x' + $script:EscapeCharacter + 'P1;2|payload' + $script:EscapeCharacter + '\y'
        $result = & (Get-Module -Name 'Bsn.Host') { param($t) Remove-BsnTerminalSequence -Text $t } $text
        $result | Should -Be 'xy'
    }

    It 'removes stand-alone BEL and NUL but keeps tab and newline' {
        $text = 'bel' + $script:BelCharacter + 'nul' + [string][char]0 + "tab`ttail`nnext"
        $result = & (Get-Module -Name 'Bsn.Host') { param($t) Remove-BsnTerminalSequence -Text $t } $text
        $result | Should -Be "belnultab`ttail`nnext"
    }
}

Describe 'ConvertTo-BsnPlainText' {
    It 'passes plain text through unchanged' {
        $result = & (Get-Module -Name 'Bsn.Host') { param($t) ConvertTo-BsnPlainText -Text $t } "line1`nline2`n"
        $result | Should -Be "line1`nline2`n"
    }

    It 'resolves carriage-return overtype (progress bars collapse to the final frame)' {
        $text = '10%' + [string][char]13 + '20%' + [string][char]13 + 'DONE' + "`n"
        $result = & (Get-Module -Name 'Bsn.Host') { param($t) ConvertTo-BsnPlainText -Text $t } $text
        $result | Should -Be "DONE`n"
    }

    It 'keeps residue from longer previous lines, like a real terminal' {
        $text = 'abcdef' + [string][char]13 + 'XY'
        $result = & (Get-Module -Name 'Bsn.Host') { param($t) ConvertTo-BsnPlainText -Text $t } $text
        $result | Should -Be 'XYcdef'
    }

    It 'resolves backspace overwrite' {
        $text = 'abc' + [string][char]8 + [string][char]8 + 'X'
        $result = & (Get-Module -Name 'Bsn.Host') { param($t) ConvertTo-BsnPlainText -Text $t } $text
        $result | Should -Be 'aXc'
    }

    It 'keeps carriage-return + line-feed pairs as line breaks' {
        $text = 'a' + [string][char]13 + "`nb"
        $result = & (Get-Module -Name 'Bsn.Host') { param($t) ConvertTo-BsnPlainText -Text $t } $text
        $result | Should -Be "a`nb"
    }

    It 'strips escape sequences and resolves overtype in one pass' {
        $text = $script:EscapeCharacter + '[2J' + '10%' + [string][char]13 + '20%' + [string][char]13 + 'DONE' + $script:EscapeCharacter + '[0m' + "`n"
        $result = & (Get-Module -Name 'Bsn.Host') { param($t) ConvertTo-BsnPlainText -Text $t } $text
        $result | Should -Be "DONE`n"
    }

    It 'keeps tab characters verbatim' {
        $result = & (Get-Module -Name 'Bsn.Host') { param($t) ConvertTo-BsnPlainText -Text $t } "a`tb"
        $result | Should -Be "a`tb"
    }
}

Describe 'Get-BsnObjectProperty' {
    It 'returns existing property values' {
        $probe = [pscustomobject]@{ version = 2; width = 100 }
        $result = & (Get-Module -Name 'Bsn.Host') { param($o) Get-BsnObjectProperty -Object $o -Name 'width' } $probe
        $result | Should -Be 100
    }

    It 'returns null for missing properties instead of throwing under strict mode' {
        $probe = [pscustomobject]@{ version = 2 }
        $result = & (Get-Module -Name 'Bsn.Host') { param($o) Get-BsnObjectProperty -Object $o -Name 'width' } $probe
        $result | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-BsnTranscript' {
    Context 'Standard header mode (default)' {
        It 'renders the full Start-Transcript-style frame from the timeline' {
            $result = ConvertTo-BsnTranscript -Path $script:SessionCastPath

            $expected = Get-BsnExpectedTranscript `
                -StartTimeText (Get-BsnExpectedTimeText -Seconds 1793895000) `
                -EndTimeText (Get-BsnExpectedTimeText -Seconds (1793895000 + 1)) `
                -HostApplication 'pwsh' `
                -BodyLines @('PS C:\> Get-Process', 'handles  npm(k)', '100%ress 50%', '')

            $result | Should -BeExactly $expected
        }

        It 'derives Host Application from env.SHELL when the cast has no command field' {
            $result = ConvertTo-BsnTranscript -Path $script:SessionCastPath
            $result | Should -BeLike "*Host Application: pwsh*"
        }

        It 'derives Host Application from the v3 command field' {
            $result = ConvertTo-BsnTranscript -Path $script:V3CastPath
            $result | Should -BeLike "*Host Application: pwsh -NoProfile*"
        }

        It 'prefers -HostApplication over the derived value' {
            $result = ConvertTo-BsnTranscript -Path $script:V3CastPath -HostApplication 'customhost -flag'
            $result | Should -BeLike "*Host Application: customhost -flag*"
        }

        It 'fills blank engine fields when parameters are supplied' {
            $result = ConvertTo-BsnTranscript -Path $script:SessionCastPath `
                -Username 'CONTOSO\jdoe' -RunAsUser 'CONTOSO\admin' -Machine 'WS01' `
                -ProcessId 4242 -PSVersion '7.4.0' -Edition 'Core'

            $expected = Get-BsnExpectedTranscript `
                -StartTimeText (Get-BsnExpectedTimeText -Seconds 1793895000) `
                -EndTimeText (Get-BsnExpectedTimeText -Seconds (1793895000 + 1)) `
                -Username 'CONTOSO\jdoe' -RunAsUser 'CONTOSO\admin' -Machine 'WS01' `
                -HostApplication 'pwsh' -ProcessId '4242' -PSVersion '7.4.0' -ExpectedPSEdition 'Core' `
                -BodyLines @('PS C:\> Get-Process', 'handles  npm(k)', '100%ress 50%', '')

            $result | Should -BeExactly $expected
        }

        It 'does not add the Transcript started line on pipeline output' {
            $result = ConvertTo-BsnTranscript -Path $script:SessionCastPath
            $result | Should -Not -BeLike '*Transcript started*'
        }
    }

    Context 'rendering (Strip)' {
        It 'strips escape sequences from output events' {
            $result = ConvertTo-BsnTranscript -Path $script:SessionCastPath
            $result.Contains([string][char]27) | Should -BeFalse
            $result.Contains('handles  npm(k)') | Should -BeTrue
        }

        It 'collapses carriage-return overtype to the final frame with residue' {
            $result = ConvertTo-BsnTranscript -Path $script:SessionCastPath
            $result.Contains('100%ress 50%') | Should -BeTrue
            $result.Contains('progress 10%') | Should -BeFalse
        }

        It 'renders v3 interval events in timeline order' {
            $result = ConvertTo-BsnTranscript -Path $script:V3CastPath
            $alphaIndex = $result.IndexOf('alpha')
            $betaIndex = $result.IndexOf('beta')
            $alphaIndex | Should -BeGreaterThan 0
            $betaIndex | Should -BeGreaterThan $alphaIndex
        }

        It 'converts a header-only cast to an empty-body transcript with matching times' {
            $result = ConvertTo-BsnTranscript -Path $script:HeaderOnlyCastPath
            $expected = Get-BsnExpectedTranscript `
                -StartTimeText (Get-BsnExpectedTimeText -Seconds 1793895000) `
                -EndTimeText (Get-BsnExpectedTimeText -Seconds 1793895000) `
                -BodyLines @('')
            $result | Should -BeExactly $expected
        }
    }

    Context 'file output' {
        It 'writes the transcript as UTF-8 without BOM with CRLF line endings and the started line' {
            $outPath = Join-Path -Path $TestDrive -ChildPath 'transcript.txt'
            $result = ConvertTo-BsnTranscript -Path $script:SessionCastPath -OutPath $outPath
            $result | Should -BeNullOrEmpty

            $bytes = [System.IO.File]::ReadAllBytes($outPath)
            $bytes[0] | Should -Not -Be 0xEF

            $content = [System.IO.File]::ReadAllText($outPath, [System.Text.Encoding]::UTF8)
            $content.Contains('Transcript started, output file is ' + $outPath) | Should -BeTrue
            ($content.Replace("`r`n", '').Contains("`n")) | Should -BeFalse -Because 'every line ending must be CRLF'

            $expected = Get-BsnExpectedTranscript `
                -StartTimeText (Get-BsnExpectedTimeText -Seconds 1793895000) `
                -EndTimeText (Get-BsnExpectedTimeText -Seconds (1793895000 + 1)) `
                -HostApplication 'pwsh' `
                -BodyLines @('PS C:\> Get-Process', 'handles  npm(k)', '100%ress 50%', '') `
                -StartedLine ('Transcript started, output file is ' + $outPath)
            $content | Should -BeExactly ($expected + "`r`n")
        }

        It 'honors -Encoding (UTF-16LE with BOM, ASCII with replacement)' {
            $unicodePath = Join-Path -Path $TestDrive -ChildPath 'unicode.txt'
            ConvertTo-BsnTranscript -Path $script:BoxRuleCastPath -OutPath $unicodePath -Encoding Unicode
            $unicodeBytes = [System.IO.File]::ReadAllBytes($unicodePath)
            $unicodeBytes[0] | Should -Be 0xFF
            $unicodeBytes[1] | Should -Be 0xFE

            $asciiPath = Join-Path -Path $TestDrive -ChildPath 'ascii.txt'
            ConvertTo-BsnTranscript -Path $script:BoxRuleCastPath -OutPath $asciiPath -Encoding ASCII
            $asciiText = [System.IO.File]::ReadAllText($asciiPath, [System.Text.Encoding]::ASCII)
            $asciiText.Contains('??rule') | Should -BeTrue
        }

        It 'rejects more than one pipeline input when -OutPath is used' {
            {
                @($script:SessionCastPath, $script:V3CastPath) |
                    ConvertTo-BsnTranscript -OutPath (Join-Path -Path $TestDrive -ChildPath 'multi.txt')
            } | Should -Throw '*converts a single cast file*'
        }

        It 'rejects a missing output directory' {
            {
                ConvertTo-BsnTranscript -Path $script:SessionCastPath -OutPath (Join-Path -Path $TestDrive -ChildPath 'missing-dir\a.txt')
            } | Should -Throw "*does not exist*"
        }

        It 'accepts pipeline input by path and by FullName' {
            $first = ConvertTo-BsnTranscript -Path $script:SessionCastPath
            $piped = @($script:SessionCastPath) | ConvertTo-BsnTranscript
            $piped | Should -BeExactly $first

            $fileInfo = Get-Item -LiteralPath $script:SessionCastPath
            $pipedByProperty = @($fileInfo) | ConvertTo-BsnTranscript
            $pipedByProperty | Should -BeExactly $first
        }
    }

    Context 'Bsn header mode (audit frame)' {
        BeforeAll {
            $script:SessionHash = Get-BsnTestCastHash -CastPath $script:SessionCastPath
            $moduleVersion = (Get-Module -Name 'Bsn.Host').Version
            $script:ExpectedRecordedBy = if ($moduleVersion) { 'Bsn.Host {0}' -f $moduleVersion } else { 'Bsn.Host' }
        }

        It 'embeds session id, recorded-by, terminal size, cast file and cast hash' {
            $result = ConvertTo-BsnTranscript -Path $script:SessionCastPath -HeaderMode Bsn

            $expectedBsnLines = @(
                ('Session Id: bsn-' + $script:SessionHash.Substring(0, 12)),
                ('Recorded By: ' + $script:ExpectedRecordedBy),
                ('Terminal Size: 100x40'),
                ('Cast File: ' + (Resolve-Path -LiteralPath $script:SessionCastPath).ProviderPath),
                ('Cast SHA256: ' + $script:SessionHash)
            )

            $expected = Get-BsnExpectedTranscript `
                -StartTimeText (Get-BsnExpectedTimeText -Seconds 1793895000) `
                -EndTimeText (Get-BsnExpectedTimeText -Seconds (1793895000 + 1)) `
                -HostApplication 'pwsh' `
                -BsnHeaderLines $expectedBsnLines `
                -BodyLines @('PS C:\> Get-Process', 'handles  npm(k)', '100%ress 50%', '')

            $result | Should -BeExactly $expected
        }

        It 'accepts a supplied session id' {
            $result = ConvertTo-BsnTranscript -Path $script:SessionCastPath -HeaderMode Bsn -SessionId 'audit-42'
            $result | Should -BeLike '*Session Id: audit-42*'
            $result | Should -BeLike ('*Cast SHA256: ' + $script:SessionHash + '*')
        }

        It 'carries the v3 terminal size and exit code' {
            $result = ConvertTo-BsnTranscript -Path $script:V3CastPath -HeaderMode Bsn
            $result | Should -BeLike '*Terminal Size: 120x30*'
            $result | Should -BeLike '*Exit Code: 7*'
            $result | Should -BeLike ('*End time: ' + (Get-BsnExpectedTimeText -Seconds (1793895000 + 0.25)) + '*')
        }

        It 'omits the audit lines in Standard mode' {
            $result = ConvertTo-BsnTranscript -Path $script:SessionCastPath
            $result | Should -Not -BeLike '*Cast SHA256*'
            $result | Should -Not -BeLike '*Session Id*'
        }
    }

    Context 'command annotation' {
        It 'inserts typed input lines when -AnnotateCommands is set' {
            $result = ConvertTo-BsnTranscript -Path $script:AnnotatedCastPath -AnnotateCommands
            $result.Contains('Password: > s3cr3t') | Should -BeTrue
        }

        It 'ignores input events by default' {
            $result = ConvertTo-BsnTranscript -Path $script:AnnotatedCastPath
            $result.Contains('s3cr3t') | Should -BeFalse
        }

        It 'strips escape sequences from annotated input' {
            $result = ConvertTo-BsnTranscript -Path $script:AnnotatedCastPath -AnnotateCommands
            $result.Contains([string][char]27) | Should -BeFalse
        }
    }

    Context 'error handling' {
        It 'rejects missing cast files' {
            { ConvertTo-BsnTranscript -Path (Join-Path -Path $TestDrive -ChildPath 'missing.cast') } | Should -Throw "*does not exist*"
        }

        It 'rejects files that are not asciicast v2 or v3' {
            $invalidPath = Join-Path -Path $TestDrive -ChildPath 'invalid.cast'
            Set-Content -LiteralPath $invalidPath -Value '{"version": 1}' -NoNewline
            { ConvertTo-BsnTranscript -Path $invalidPath } | Should -Throw '*not an asciicast v2 or v3*'
        }
    }
}
