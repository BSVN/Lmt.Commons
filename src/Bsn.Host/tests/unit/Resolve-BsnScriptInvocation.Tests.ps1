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

    # Fake script(1) binaries are shell shims: they need a Unix host (chmod/exec).
    if ((Get-BsnOperatingSystem) -ne $script:BsnWindows) {
        $script:AcceptingShimPath = Join-Path -Path $TestDrive -ChildPath 'accepting-script'
        Set-Content -LiteralPath $script:AcceptingShimPath -Value "#!/bin/sh`nexit 0" -NoNewline
        & chmod +x $script:AcceptingShimPath

        $script:RejectingShimPath = Join-Path -Path $TestDrive -ChildPath 'rejecting-script'
        Set-Content -LiteralPath $script:RejectingShimPath -Value "#!/bin/sh`nexit 1" -NoNewline
        & chmod +x $script:RejectingShimPath
    }
}

Describe 'Resolve-BsnScriptInvocation' {
    # https://github.com/BSVN/Lmt.Commons/issues/5 (Linux verification):
    # util-linux 2.39+ rejects combining --log-out with a trailing positional
    # typescript file, so the engine probes the installed binary and picks the
    # invocation shape it accepts. The probe runs a no-op child ('-c "true"')
    # through the shim, so the shim's exit code decides the branch.
    It 'keeps the classic positional form when script(1) accepts it (util-linux <= 2.37)' {
        if ((Get-BsnOperatingSystem) -eq $script:BsnWindows) {
            Set-ItResult -Skipped -Because 'the fake script(1) shims are Unix shell executables; the probe is exercised end to end by the Unix system tests on Linux CI.'
        }

        # Resolve-BsnScriptInvocation is private: invoke it through the
        # defining module's scope (the same way the engine calls it).
        $arguments = & (Get-Module -Name 'Bsn.Host') {
            param($p, $c, $t, $o)
            Resolve-BsnScriptInvocation -ScriptPath $p -Command $c -TimingPath $t -OutputPath $o
        } $script:AcceptingShimPath 'echo MARKER' '/tmp/t.json' '/tmp/o.log'

        $arguments | Should -BeLike '*-c "echo MARKER" --log-timing "/tmp/t.json" --log-out "/tmp/o.log" /dev/null*' -Because 'a compatible binary must keep the historically tested positional form'
    }

    It 'falls back to the options-only form when script(1) rejects the positional file (util-linux >= 2.39)' {
        if ((Get-BsnOperatingSystem) -eq $script:BsnWindows) {
            Set-ItResult -Skipped -Because 'the fake script(1) shims are Unix shell executables; the probe is exercised end to end by the Unix system tests on Linux CI.'
        }

        $arguments = & (Get-Module -Name 'Bsn.Host') {
            param($p, $c, $t, $o)
            Resolve-BsnScriptInvocation -ScriptPath $p -Command $c -TimingPath $t -OutputPath $o
        } $script:RejectingShimPath 'echo MARKER' '/tmp/t.json' '/tmp/o.log'

        $arguments | Should -BeLike '*-c "echo MARKER" --log-timing "/tmp/t.json" --log-out "/tmp/o.log"*' -Because 'a rejecting binary must get the options-only invocation'
        $arguments | Should -Not -BeLike '*/dev/null*' -Because 'the positional typescript file is what util-linux >= 2.39 rejects'
    }

    It 'includes the recorded command and both log paths in every invocation shape' {
        if ((Get-BsnOperatingSystem) -eq $script:BsnWindows) {
            Set-ItResult -Skipped -Because 'the fake script(1) shims are Unix shell executables; the probe is exercised end to end by the Unix system tests on Linux CI.'
        }

        foreach ($shim in @($script:AcceptingShimPath, $script:RejectingShimPath)) {
            $arguments = & (Get-Module -Name 'Bsn.Host') {
                param($p, $c, $t, $o)
                Resolve-BsnScriptInvocation -ScriptPath $p -Command $c -TimingPath $t -OutputPath $o
            } $shim 'uname -s' '/tmp/t.json' '/tmp/o.log'
            $arguments.Contains('uname -s') | Should -BeTrue -Because 'the recorded command must be part of the -c argument'
            $arguments.Contains('/tmp/t.json') | Should -BeTrue -Because 'the timing log path must be passed to --log-timing'
            $arguments.Contains('/tmp/o.log') | Should -BeTrue -Because 'the output log path must be passed to --log-out'
        }
    }
}
