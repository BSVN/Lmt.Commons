BeforeAll {
    $moduleRoot = Split-Path -Parent -Path (Split-Path -Parent -Path $PSScriptRoot)
    # Make the repo sibling module Bsn.Common resolvable for RequiredModules validation.
    $env:PSModulePath = '{0}{1}{2}' -f (Split-Path -Parent -Path $moduleRoot), [System.IO.Path]::PathSeparator, $env:PSModulePath
    $script:ManifestPath = Join-Path -Path $moduleRoot -ChildPath 'Bsn.Host.psd1'
    # The module's DLL may already be loaded in this process (e.g., by PSScriptAnalyzer
    # analyzing the manifest), which makes Import-Module fail with FileLoadException.
    # Fall back to importing the psm1 directly - the assembly is already in memory.
    try {
        Import-Module -Name $script:ManifestPath -Force -ErrorAction 'Stop'
    }
    catch [System.IO.FileLoadException] {
        Import-Module -Name (Join-Path -Path $moduleRoot 'Bsn.Host.psm1') -Force -ErrorAction 'Stop'
    }

    # Query sequence building blocks. Test names and -TestCases data must stay
    # free of raw ESC characters: ESC (0x1B) is invalid in XML 1.0 and crashes
    # the NUnit export; sequences are assembled inside each test body instead.
    $script:Esc = [string][char]27
    $script:Bel = [string][char]7
    $script:St = "$([string][char]27)\"
}

Describe 'TerminalQueryFilter' {
    # https://github.com/BSVN/Lmt.Commons/issues/20

    Context 'response-eliciting query sequences are dropped' {
        It 'drops the XTWINOPS pixel-size query (the reported 4;600;1200 artifact)' {
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $filter.Filter("$($script:Esc)[14t") | Should -Be ([string]::Empty)
        }

        It 'drops DSR cursor-position report requests' {
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            foreach ($body in @('6n', '?6n', '0n')) {
                $filter.Filter("$($script:Esc)[$body") | Should -Be ([string]::Empty)
            }
        }

        It 'drops device-attribute (DA) capability queries' {
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            foreach ($body in @('c', '0c', '>c', '>85;100c', '=67;84;1c')) {
                $filter.Filter("$($script:Esc)[$body") | Should -Be ([string]::Empty)
            }
        }

        It 'drops the XTVERSION query' {
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $filter.Filter("$($script:Esc)[>0q") | Should -Be ([string]::Empty)
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $filter.Filter("$($script:Esc)[>q") | Should -Be ([string]::Empty)
        }

        It 'drops the kitty keyboard protocol query' {
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $filter.Filter("$($script:Esc)[?u") | Should -Be ([string]::Empty)
        }

        It 'drops DECRQM mode requests (DEC form)' {
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $filter.Filter("$($script:Esc)[?2026`$p") | Should -Be ([string]::Empty)
        }

        It 'drops every XTWINOPS single-parameter report request' {
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            foreach ($parameter in @('5', '6', '11', '13', '14', '16', '18')) {
                $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
                $filter.Filter("$($script:Esc)[$parameter" + 't') | Should -Be ([string]::Empty)
            }
        }

        It 'drops OSC default-color queries (BEL and ST terminated)' {
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $filter.Filter("$($script:Esc)]10;?$($script:Bel)") | Should -Be ([string]::Empty)
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $filter.Filter("$($script:Esc)]11;?$($script:Bel)") | Should -Be ([string]::Empty)
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $filter.Filter("$($script:Esc)]10;?$($script:St)") | Should -Be ([string]::Empty)
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $filter.Filter("$($script:Esc)]11;?$($script:St)") | Should -Be ([string]::Empty)
        }

        It 'drops OSC palette queries (OSC 4;<index>;?)' {
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $filter.Filter("$($script:Esc)]4;1;?$($script:Bel)") | Should -Be ([string]::Empty)
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $filter.Filter("$($script:Esc)]4;12;?$($script:Bel)") | Should -Be ([string]::Empty)
        }
    }

    Context 'set forms, answers and ordinary content are preserved' {
        It 'keeps the XTWINOPS SET forms' {
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $filter.Filter("$($script:Esc)[4;600;1200t") | Should -Be "$($script:Esc)[4;600;1200t"
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $filter.Filter("$($script:Esc)[8;24;80t") | Should -Be "$($script:Esc)[8;24;80t"
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $filter.Filter("$($script:Esc)[3;0t") | Should -Be "$($script:Esc)[3;0t"
        }

        It 'keeps ordinary playback content untouched' {
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $styled = "$($script:Esc)[38;2;255;0;0mstyled$($script:Esc)[0m"
            $filter.Filter($styled) | Should -Be $styled
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $cursor = "$($script:Esc)[2;3Hcursor move"
            $filter.Filter($cursor) | Should -Be $cursor
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $altScreen = "$($script:Esc)[?1049h$($script:Esc)[?1049l"
            $filter.Filter($altScreen) | Should -Be $altScreen
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $title = "$($script:Esc)]0;window title$($script:Bel)"
            $filter.Filter($title) | Should -Be $title
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $filter.Filter('hello ─ ╭ world') | Should -Be 'hello ─ ╭ world'
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $filter.Filter("plain text`r`nwith lines") | Should -Be "plain text`r`nwith lines"
        }

        It 'keeps the DECRPM answer form (a report, not a request)' {
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $answer = "$($script:Esc)[?2026;2`$y"
            $filter.Filter($answer) | Should -Be $answer
        }

        It 'keeps DECSCUSR (cursor style has a space intermediate, no > prefix)' {
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $cursorStyle = "$($script:Esc)[3 q"
            $filter.Filter($cursorStyle) | Should -Be $cursorStyle
        }
    }

    Context 'chunk boundaries (the filter state persists across Filter calls)' {
        It 'drops a query sequence split across two chunks' {
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $part1 = $filter.Filter("$($script:Esc)[1")
            $part2 = $filter.Filter('4t')
            ($part1 + $part2) | Should -Be ([string]::Empty)
        }

        It 'drops a query sequence split mid-parameter' {
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $part1 = $filter.Filter("$($script:Esc)[?2")
            $part2 = $filter.Filter("026`$p")
            ($part1 + $part2) | Should -Be ([string]::Empty)
        }

        It 'drops an OSC query split across three chunks' {
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $part1 = $filter.Filter("$($script:Esc)]")
            $part2 = $filter.Filter('11;')
            $part3 = $filter.Filter("?$($script:Bel)")
            ($part1 + $part2 + $part3) | Should -Be ([string]::Empty)
        }

        It 'keeps a kept-sequence split across chunks (SGR)' {
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $part1 = $filter.Filter("$($script:Esc)[38")
            $part2 = $filter.Filter(';2;1;2;3m')
            ($part1 + $part2) | Should -Be "$($script:Esc)[38;2;1;2;3m"
        }

        It 'emits content before a query and after it, split arbitrarily' {
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $collected = [System.Text.StringBuilder]::new()
            foreach ($chunk in @('before', "$($script:Esc)[1", '4t', 'middle', "$($script:Esc)[6n", 'after')) {
                [void]$collected.Append($filter.Filter($chunk))
            }

            $collected.ToString() | Should -Be 'beforemiddleafter'
        }
    }

    Context 'end-of-stream handling' {
        It 'flushes a held lone ESC as real content' {
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $filter.Filter($script:Esc) | Should -Be ([string]::Empty)   # held: could become a sequence
            $filter.FlushRemaining() | Should -Be $script:Esc
        }

        It 'flushes a held partial sequence as real content' {
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $partial = "$($script:Esc)[94"
            $null = $filter.Filter($partial)
            $filter.FlushRemaining() | Should -Be $partial
        }

        It 'continues filtering correctly after a flush' {
            $filter = [Bsn.Host.Interop.TerminalQueryFilter]::new()
            $null = $filter.Filter($script:Esc)
            $null = $filter.FlushRemaining()
            $filter.Filter("$($script:Esc)[14t") | Should -Be ([string]::Empty)   # still drops queries after a flush
        }
    }
}
