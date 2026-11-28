<#
.SYNOPSIS
    Builds the script(1) arguments for a timing-based recording, probing the
    installed binary for invocation compatibility.

.DESCRIPTION
    util-linux changed script(1) invocation compatibility across releases:

    - util-linux 2.39+ (Ubuntu 24.04, 26.04) REJECTS combining --log-out
      with a trailing positional typescript file ('unexpected number of
      arguments') - the recording process exits immediately and every cast
      comes back empty.
    - util-linux 2.37 (Ubuntu 22.04) and older releases with --log-timing
      accept both shapes.

    This helper probes the installed binary once with a no-op child using
    the classic positional form: where it is accepted, the historically
    tested invocation is kept; where it is rejected, the options-only form
    is used. No version string parsing is involved, so any future
    util-linux release is handled by the same probe.

    The arguments come back as a list, one element per argument, and the
    recorded command is ONE element. ProcessStartInfo.ArgumentList hands
    every element to script(1) as it is, so a command may contain quotes,
    pipes, redirections and anything else. Assembling one argument string
    with the command inside quotes instead broke every such command
    ('unexpected number of arguments', and a cast without events).

    Kept private (invoked by the Start-InteractiveTranscript engine).

.PARAMETER ScriptPath
    Path of the installed script(1) binary.

.PARAMETER Command
    Command to record, for script(1)'s -c option.

.PARAMETER TimingPath
    Path of the util-linux script(1) --log-timing log.

.PARAMETER OutputPath
    Path of the util-linux script(1) --log-out stream.

.OUTPUTS
    [string[]]
        The arguments for script(1), without the binary itself.
#>
function Resolve-BsnScriptInvocation {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [string]$TimingPath,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    $arguments = @('-q', '-f', '-e', '-c', $Command, '--log-timing', $TimingPath, '--log-out', $OutputPath)

    $probeTimingPath = [System.IO.Path]::GetTempFileName()
    $probeOutputPath = [System.IO.Path]::GetTempFileName()
    $probeProcess = $null
    try {
        $probeInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $probeInfo.FileName = $ScriptPath
        $probeInfo.UseShellExecute = $false
        $probeInfo.RedirectStandardError = $true
        foreach ($probeArgument in @('-q', '-f', '-e', '-c', 'true', '--log-timing', $probeTimingPath, '--log-out', $probeOutputPath, '/dev/null')) {
            $probeInfo.ArgumentList.Add($probeArgument)
        }
        $probeProcess = [System.Diagnostics.Process]::Start($probeInfo)
        $acceptsPositionalFile = $false
        if (-not $probeProcess.WaitForExit(10000)) {
            $probeProcess.Kill()
            Write-Verbose -Message 'script(1) invocation probe timed out; using the options-only form.'
        }
        else {
            # Drain stderr so the probe's rejection message never surfaces to the user.
            $null = $probeProcess.StandardError.ReadToEnd()
            $acceptsPositionalFile = ($probeProcess.ExitCode -eq 0)
            if ($acceptsPositionalFile) {
                Write-Verbose -Message 'script(1) accepts the positional typescript file; using the classic invocation.'
            }
            else {
                Write-Verbose -Message ('script(1) rejected the positional typescript file (exit {0}); using the options-only form.' -f $probeProcess.ExitCode)
            }
        }

        if ($acceptsPositionalFile) {
            return ($arguments + '/dev/null')
        }
        return $arguments
    }
    finally {
        if ($probeProcess) {
            $probeProcess.Dispose()
        }
        Remove-Item -LiteralPath $probeTimingPath, $probeOutputPath -Force -ErrorAction 'SilentlyContinue'
    }
}
