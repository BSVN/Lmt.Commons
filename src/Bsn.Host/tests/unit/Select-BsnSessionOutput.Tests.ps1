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

Describe 'Select-BsnSessionOutput' {
    # script(1) may write a start and a done message of its own into the log
    # it keeps. The bytes of a log below are what util-linux 2.41 writes for
    # 'echo one; sleep 0.3; echo two': the messages with LF line endings
    # around the session's output with CRLF, and one extra LF in front of
    # the done message. util-linux always writes them; macOS's BSD script(1)
    # leaves them out in quiet mode. The test calls the private function
    # through the defining module's scope.
    BeforeAll {
        $script:Utf8 = [System.Text.Encoding]::UTF8
        $script:StartMessage = 'Script started on 2026-11-28 01:22:25+03:30 [COMMAND="echo one; sleep 0.3; echo two" <not executed on terminal>]' + [char]10
        $script:DoneMessage = [char]10 + 'Script done on 2026-11-28 01:22:26+03:30 [COMMAND_EXIT_CODE="0"]' + [char]10
        $script:Output = 'one' + "`r`n" + 'two' + "`r`n"

        $script:Select = {
            param([byte[]]$Bytes, [int]$TimedBytes = -1)
            $kept = & (Get-Module -Name 'Bsn.Host') { param($b, $t) Select-BsnSessionOutput -Bytes $b -TimedBytes $t } $Bytes $TimedBytes
            return ,([byte[]]$kept)
        }
        $script:Text = {
            param([byte[]]$Bytes) return $script:Utf8.GetString($Bytes)
        }
    }

    Context 'with a timing log (util-linux)' {
        It 'leaves the start and the done message out, around the session output' {
            $bytes = $script:Utf8.GetBytes($script:StartMessage + $script:Output + $script:DoneMessage)

            $kept = & $script:Select -Bytes $bytes -TimedBytes $script:Output.Length

            & $script:Text $kept | Should -BeExactly $script:Output
        }

        It 'leaves a start message out when the session was cut off before the done message' {
            $bytes = $script:Utf8.GetBytes($script:StartMessage + $script:Output)

            $kept = & $script:Select -Bytes $bytes -TimedBytes $script:Output.Length

            & $script:Text $kept | Should -BeExactly $script:Output
        }

        It 'leaves a done message out when the log does not begin with a start message' {
            $bytes = $script:Utf8.GetBytes($script:Output + $script:DoneMessage)

            $kept = & $script:Select -Bytes $bytes -TimedBytes $script:Output.Length

            & $script:Text $kept | Should -BeExactly $script:Output
        }

        It 'keeps output that the timing log does not cover, up to the done message' {
            # script(1) was killed before it noted the last chunk: the bytes
            # after the timed part are output, not part of the message.
            $bytes = $script:Utf8.GetBytes($script:StartMessage + $script:Output + $script:DoneMessage)

            $kept = & $script:Select -Bytes $bytes -TimedBytes 5

            & $script:Text $kept | Should -BeExactly $script:Output
        }

        It 'keeps a first line that reads like the start message when the timing log covers the whole file' {
            # A session may well print a line that begins like script(1)'s
            # message. When nothing in the file is untimed there is no
            # message to leave out, so the line is output.
            $text = 'Script started on purpose' + "`r`n" + 'real' + "`r`n"
            $bytes = $script:Utf8.GetBytes($text)

            $kept = & $script:Select -Bytes $bytes -TimedBytes $bytes.Length

            & $script:Text $kept | Should -BeExactly $text
        }

        It 'returns nothing for a log that is only the start message' {
            $kept = & $script:Select -Bytes ($script:Utf8.GetBytes($script:StartMessage)) -TimedBytes 0

            @($kept).Count | Should -Be 0
        }

        It 'returns nothing for a log that is only the start message, cut off before its line break' {
            $cutOff = $script:StartMessage.TrimEnd([char]10)
            $kept = & $script:Select -Bytes ($script:Utf8.GetBytes($cutOff)) -TimedBytes 0

            @($kept).Count | Should -Be 0
        }
    }

    Context 'without a timing log (macOS)' {
        It 'leaves the start and the done message out, around the session output' {
            $bytes = $script:Utf8.GetBytes($script:StartMessage + $script:Output + $script:DoneMessage)

            $kept = & $script:Select -Bytes $bytes

            & $script:Text $kept | Should -BeExactly $script:Output
        }

        It 'keeps a first line that reads like the start message when the last line is no done message' {
            # Nothing tells that line from output, so it is output.
            $text = 'Script started on purpose' + "`r`n" + 'real' + "`r`n"
            $bytes = $script:Utf8.GetBytes($text)

            $kept = & $script:Select -Bytes $bytes

            & $script:Text $kept | Should -BeExactly $text
        }

        It 'keeps a last line that reads like the done message when the first line is no start message' {
            $text = $script:Output + $script:DoneMessage
            $bytes = $script:Utf8.GetBytes($text)

            $kept = & $script:Select -Bytes $bytes

            & $script:Text $kept | Should -BeExactly $text
        }
    }

    Context 'for every log' {
        It 'leaves a log without messages alone' {
            $bytes = $script:Utf8.GetBytes($script:Output + 'three' + "`r`n")

            $kept = & $script:Select -Bytes $bytes

            [System.BitConverter]::ToString($kept) | Should -Be ([System.BitConverter]::ToString($bytes)) -Because 'the log must come back byte for byte'
        }

        It 'keeps a line that reads like the done message when it is not the last line' {
            $text = 'before' + "`r`n" + 'Script done on purpose' + "`r`n" + 'after' + "`r`n"
            $bytes = $script:Utf8.GetBytes($text)

            $kept = & $script:Select -Bytes $bytes -TimedBytes $bytes.Length

            & $script:Text $kept | Should -BeExactly $text
        }

        It 'does not take a long last line for the done message' {
            $longLine = 'x' * 600
            $text = 'Script done on' + $longLine + "`r`n"
            $bytes = $script:Utf8.GetBytes($text)

            $kept = & $script:Select -Bytes $bytes -TimedBytes 0

            & $script:Text $kept | Should -BeExactly $text
        }

        It 'returns nothing for an empty log' {
            $kept = & $script:Select -Bytes ([byte[]]@())

            @($kept).Count | Should -Be 0
        }
    }
}
