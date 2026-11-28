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
    # test scope; pull the enum value from the defining module's own scope
    # (see AGENTS.md and the Start-InteractiveTranscript tests).
    $script:BsnWindows = & (Get-Module -Name 'Bsn.Common') { [BsnOperatingSystem]::Windows }

    # The engine finds script(1) on PATH. Each flavour gets a directory with
    # a shell shim named 'script' that the test puts first on PATH, so that
    # the Unix engine is driven through BOTH flavours on every Unix host:
    # the util-linux one with timing logs and messages in its output log,
    # and the BSD one (macOS) with a plain typescript. The shims are shell
    # scripts: they need a Unix host, so on Windows these tests are skipped.
    if ((Get-BsnOperatingSystem) -ne $script:BsnWindows) {
        # util-linux: script -q -f -e -c COMMAND --log-timing FILE --log-out FILE [FILE].
        # It writes the start and the done message into the output log, around
        # the command's output, and notes one timed chunk of that output.
        $script:UtilLinuxShim = @(
            '#!/bin/sh',
            '# Fake util-linux script(1) for the Bsn.Host tests.',
            '[ -n "$BSN_TEST_SCRIPT_ARGS" ] && printf ''%s\n'' "$@" > "$BSN_TEST_SCRIPT_ARGS"',
            'if [ "$1" = "--help" ]; then',
            '    echo "usage: script [options] [file]"',
            '    echo "  -c, --command <command>  run the command rather than an interactive shell"',
            '    echo "  -f, --flush              run flush after each write"',
            '    echo "  -e, --return              return exit code of the child process"',
            '    echo "  -O, --log-out <file>      log output to file"',
            '    echo "  -T, --log-timing <file>   log timing to file"',
            '    exit 0',
            'fi',
            '[ "$1" = "-q" ] && shift',
            '[ "$1" = "-f" ] && shift',
            '[ "$1" = "-e" ] && shift',
            '[ "$1" = "-c" ] && shift',
            'command=$1; shift',
            '[ "$1" = "--log-timing" ] && shift',
            'timing=$1; shift',
            '[ "$1" = "--log-out" ] && shift',
            'output=$1; shift',
            'body=$(mktemp)',
            'sh -c "$command" > "$body" 2>&1',
            'status=$?',
            'printf ''Script started on fake [COMMAND="%s" <not executed on terminal>]\n'' "$command" > "$output"',
            'cat "$body" >> "$output"',
            'printf ''\nScript done on fake [COMMAND_EXIT_CODE="%s"]\n'' "$status" >> "$output"',
            'printf ''0.500000 %s\n'' "$(wc -c < "$body" | awk ''{print $1}'')" > "$timing"',
            'rm -f "$body"',
            'exit $status'
        ) -join "`n"

        # BSD (macOS): script -q -t TIME FILE COMMAND... . It has no -c option
        # and no timing log; a quiet run writes nothing but the output.
        $script:BsdShim = @(
            '#!/bin/sh',
            '# Fake BSD script(1) for the Bsn.Host tests.',
            '[ -n "$BSN_TEST_SCRIPT_ARGS" ] && printf ''%s\n'' "$@" > "$BSN_TEST_SCRIPT_ARGS"',
            'if [ "$1" = "--help" ]; then',
            '    echo "usage: script [-adkpqr] [-F pipe] [-t time] [file [command ...]]" >&2',
            '    exit 1',
            'fi',
            'while [ "$#" -gt 0 ]; do',
            '    case "$1" in',
            '        -t) shift 2 ;;',
            '        -*) shift ;;',
            '        *) break ;;',
            '    esac',
            'done',
            'file=$1; shift',
            '"$@" > "$file" 2>&1',
            'exit $?'
        ) -join "`n"
    }

    # What the recorded command prints, and a command that carries quotes,
    # pipes, an ampersand, redirections and a caret inside it: the engine
    # must hand it to script(1) as one argument.
    $script:Payload = "ENGINE-OK`nQUOTE-OK a|b&c<d>e^f`n"
    $script:Command = 'printf ''ENGINE-OK\n''; printf ''%s\n'' "QUOTE-OK a|b&c<d>e^f"'

    # Runs the engine with the given shim first on PATH. Returns the
    # engine's result, the warnings it wrote, the cast's events and the
    # arguments script(1) got.
    $script:InvokeEngine = {
        param([string]$Shim, [string]$Command, [int]$CastVersion = 2, [switch]$RecordInput)
        $shimDirectory = Join-Path -Path $TestDrive -ChildPath ('shim-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType 'Directory' -Path $shimDirectory -Force
        $shimPath = Join-Path -Path $shimDirectory -ChildPath 'script'
        Set-Content -LiteralPath $shimPath -Value $Shim -NoNewline
        & chmod +x $shimPath
        $argsPath = Join-Path -Path $shimDirectory -ChildPath 'script-args.txt'
        $castPath = Join-Path -Path $shimDirectory -ChildPath 'session.cast'

        $previousPath = $env:PATH
        $previousArgsFile = $env:BSN_TEST_SCRIPT_ARGS
        try {
            $env:PATH = $shimDirectory + [System.IO.Path]::PathSeparator + $env:PATH
            $env:BSN_TEST_SCRIPT_ARGS = $argsPath
            $outputs = @(& (Get-Module -Name 'Bsn.Host') {
                param($c, $p, $v, $r) Start-BsnUnixPtyRecording -Command $c -CastPath $p -CastVersion $v -ShellName 'sh' -RecordInput:$r
            } $Command $castPath $CastVersion $RecordInput.IsPresent 3>&1)
        }
        finally {
            $env:PATH = $previousPath
            $env:BSN_TEST_SCRIPT_ARGS = $previousArgsFile
        }

        $lines = @([System.IO.File]::ReadAllLines($castPath, [System.Text.Encoding]::UTF8))
        $events = @($lines | Select-Object -Skip 1 | ForEach-Object -Process { , ($_ | ConvertFrom-Json) })
        $arguments = @([System.IO.File]::ReadAllLines($argsPath))
        $warnings = @($outputs | Where-Object -FilterScript { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object -Process { $_.Message })
        $result = @($outputs | Where-Object -FilterScript { $_ -isnot [System.Management.Automation.WarningRecord] }) | Select-Object -Last 1
        return [pscustomobject]@{ Result = $result; Warnings = $warnings; Header = ($lines[0] | ConvertFrom-Json); Events = $events; Arguments = $arguments }
    }
}

Describe 'Start-BsnUnixPtyRecording' {
    BeforeEach {
        if ((Get-BsnOperatingSystem) -eq $script:BsnWindows) {
            Set-ItResult -Skipped -Because 'the fake script(1) shims are Unix shell executables.'
        }
    }

    Context 'with util-linux script(1) (timing log, messages in the output log)' {
        It 'records the command output alone, timed as script(1) noted it' {
            $run = & $script:InvokeEngine -Shim $script:UtilLinuxShim -Command $script:Command

            $run.Result.ExitCode | Should -Be 0
            $run.Result.StoppedByRequest | Should -BeFalse
            $run.Header.version | Should -Be 2
            @($run.Events).Count | Should -Be 1 -Because 'the shim noted one timed chunk'
            $run.Events[0][0] | Should -Be 0.5
            $run.Events[0][1] | Should -Be 'o'
            $run.Events[0][2] | Should -BeExactly $script:Payload -Because 'the cast holds the session output and neither of the script(1) messages'
        }

        It 'hands the command to script(1) as one argument, whatever it contains' {
            $run = & $script:InvokeEngine -Shim $script:UtilLinuxShim -Command $script:Command

            $commandIndex = [array]::IndexOf($run.Arguments, '-c') + 1
            $run.Arguments[$commandIndex] | Should -BeExactly $script:Command
            $run.Arguments[0..3] -join ' ' | Should -Be '-q -f -e -c'
            $run.Arguments[-1] | Should -Be '/dev/null' -Because 'the shim accepts the positional typescript file'
            [array]::IndexOf($run.Arguments, '--log-timing') | Should -Be 5
            [array]::IndexOf($run.Arguments, '--log-out') | Should -Be 7
        }

        It 'returns the exit code of the recorded command' {
            $run = & $script:InvokeEngine -Shim $script:UtilLinuxShim -Command 'exit 3'

            $run.Result.ExitCode | Should -Be 3
        }
    }

    Context 'with either script(1)' {
        It 'fails with guidance when script(1) is not on PATH' {
            $emptyPath = (New-Item -ItemType 'Directory' -Path (Join-Path -Path $TestDrive -ChildPath 'no-script-here') -Force).FullName
            $previousPath = $env:PATH
            try {
                $env:PATH = $emptyPath
                { & (Get-Module -Name 'Bsn.Host') { Start-BsnUnixPtyRecording -Command 'true' -CastPath '/dev/null' } } | Should -Throw '*require the script(1) utility, which was not found on PATH*'
            }
            finally {
                $env:PATH = $previousPath
            }
        }

        It 'warns that keystrokes are not recorded on Unix, and records the output anyway' {
            $run = & $script:InvokeEngine -Shim $script:UtilLinuxShim -Command $script:Command -RecordInput

            $run.Warnings.Count | Should -Be 1
            $run.Warnings[0] | Should -BeLike '*Recording keyboard input is not supported on Unix*'
            $run.Events[0][2] | Should -BeExactly $script:Payload
        }
    }

    Context 'with BSD script(1) (macOS: a plain typescript, no timing log)' {
        It 'records the command output line by line' {
            $run = & $script:InvokeEngine -Shim $script:BsdShim -Command $script:Command

            $run.Result.ExitCode | Should -Be 0
            $run.Header.version | Should -Be 2
            (@($run.Events | ForEach-Object -Process { [string]$_[2] }) -join '') | Should -BeExactly $script:Payload
            @($run.Events | Where-Object -FilterScript { $_[1] -ne 'o' }).Count | Should -Be 0
        }

        It 'runs the command through /bin/sh and asks for the log to be flushed as it goes' {
            $run = & $script:InvokeEngine -Shim $script:BsdShim -Command $script:Command

            # -t 0: BSD script(1) flushes its file every 30 seconds by
            # default, and a stopped recording loses what is still buffered.
            $run.Arguments[0..2] -join ' ' | Should -Be '-q -t 0'
            $run.Arguments[3] | Should -BeLike '*/*.tmp' -Because 'then comes the typescript file'
            $run.Arguments[4..5] -join ' ' | Should -Be '/bin/sh -c'
            $run.Arguments[6] | Should -BeExactly $script:Command
            @($run.Arguments).Count | Should -Be 7
        }

        It 'returns the exit code of the recorded command' {
            $run = & $script:InvokeEngine -Shim $script:BsdShim -Command 'exit 3'

            $run.Result.ExitCode | Should -Be 3
        }
    }
}
