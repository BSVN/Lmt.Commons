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

    Kept private (invoked by the Start-InteractiveTranscript engine).
#>
function Resolve-BsnScriptInvocation {
    [CmdletBinding()]
    [OutputType([string])]
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

    $probeTimingPath = [System.IO.Path]::GetTempFileName()
    $probeOutputPath = [System.IO.Path]::GetTempFileName()
    try {
        $probeInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $probeInfo.FileName = $ScriptPath
        $probeInfo.UseShellExecute = $false
        $probeInfo.RedirectStandardError = $true
        $probeInfo.Arguments = ('-q -f -e -c "true" --log-timing "{0}" --log-out "{1}" /dev/null' -f $probeTimingPath, $probeOutputPath)
        $probeProcess = [System.Diagnostics.Process]::Start($probeInfo)
        if (-not $probeProcess.WaitForExit(10000)) {
            $probeProcess.Kill()
            Write-Verbose -Message 'script(1) invocation probe timed out; using the options-only form.'
            return ('-q -f -e -c "{0}" --log-timing "{1}" --log-out "{2}"' -f $Command, $TimingPath, $OutputPath)
        }

        # Drain stderr so the probe's rejection message never surfaces to the user.
        $null = $probeProcess.StandardError.ReadToEnd()

        if ($probeProcess.ExitCode -eq 0) {
            Write-Verbose -Message 'script(1) accepts the positional typescript file; using the classic invocation.'
            return ('-q -f -e -c "{0}" --log-timing "{1}" --log-out "{2}" /dev/null' -f $Command, $TimingPath, $OutputPath)
        }

        Write-Verbose -Message ('script(1) rejected the positional typescript file (exit {0}); using the options-only form.' -f $probeProcess.ExitCode)
        return ('-q -f -e -c "{0}" --log-timing "{1}" --log-out "{2}"' -f $Command, $TimingPath, $OutputPath)
    }
    finally {
        Remove-Item -LiteralPath $probeTimingPath, $probeOutputPath -Force -ErrorAction 'SilentlyContinue'
    }
}
