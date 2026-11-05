<#
.SYNOPSIS
    Records a command inside a Unix pseudo-terminal via script(1) to a cast file.

.DESCRIPTION
    Uses the system script(1) utility, which runs the command inside a
    pseudo-terminal, proxies it to the real terminal and logs the stream:

    - util-linux script (most Linux distributions): records with exact
      timing (--log-timing/--log-out) which is then converted to asciicast v2.
    - BSD script (macOS): records the raw stream only; timestamps are
      approximated by spreading line events across the measured duration.

    Input recording is not supported on Unix in this release; a warning is
    emitted when -RecordInput is requested.
#>
function Start-BsnUnixPtyRecording {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Confirmation is owned by the public Start-InteractiveTranscript cmdlet.')]
    [CmdletBinding()]
    param(
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [string]$CastPath,

        [switch]$RecordInput
    )

    $scriptTool = Get-Command -Name 'script' -ErrorAction 'SilentlyContinue'
    if (-not $scriptTool) {
        throw 'Interactive transcripts on Unix require the script(1) utility, which was not found on PATH.'
    }

    if ($RecordInput.IsPresent) {
        Write-Warning -Message 'Recording keyboard input is not supported on Unix platforms yet; only terminal output is recorded.'
    }

    $width = 80
    $height = 24
    try {
        $tputColumns = (& tput cols 2>$null)
        if ($tputColumns) { $width = [int]$tputColumns }
    }
    catch {
        Write-Verbose -Message ("Could not query terminal width: {0}" -f $_.Exception.Message)
    }
    try {
        $tputLines = (& tput lines 2>$null)
        if ($tputLines) { $height = [int]$tputLines }
    }
    catch {
        Write-Verbose -Message ("Could not query terminal height: {0}" -f $_.Exception.Message)
    }

    # util-linux script supports exact timing logs; BSD script does not.
    $scriptHelp = (& $scriptTool.Source --help 2>&1 | Out-String)
    $supportsTiming = $scriptHelp -match '--log-timing'

    $temporaryPaths = @()
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $exitCode = 0
    try {
        if ($supportsTiming) {
            $timingPath = [System.IO.Path]::GetTempFileName()
            $outputPath = [System.IO.Path]::GetTempFileName()
            $temporaryPaths = @($timingPath, $outputPath)

            $recordedCommand = if ($Command) { $Command } else { Get-BsnDefaultShell }

            & $scriptTool.Source -q -f -e -c $recordedCommand --log-timing $timingPath --log-out $outputPath '/dev/null'
            $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
            $stopwatch.Stop()

            ConvertTo-BsnAsciicast -OutputPath $outputPath -TimingPath $timingPath -CastPath $CastPath -Width $width -Height $height
        }
        else {
            $rawPath = [System.IO.Path]::GetTempFileName()
            $temporaryPaths = @($rawPath)

            $scriptArguments = @('-q', $rawPath)
            if ($Command) {
                $scriptArguments += @('/bin/sh', '-c', $Command)
            }
            else {
                $scriptArguments += @(Get-BsnDefaultShell)
            }

            & $scriptTool.Source @scriptArguments
            $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
            $stopwatch.Stop()

            ConvertTo-BsnAsciicast -OutputPath $rawPath -CastPath $CastPath -Width $width -Height $height -DurationSec $stopwatch.Elapsed.TotalSeconds
        }
    }
    finally {
        $stopwatch.Stop()
        foreach ($temporaryPath in $temporaryPaths) {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction 'SilentlyContinue'
            }
        }
    }

    return [pscustomobject]@{
        ExitCode    = $exitCode
        DurationSec = $stopwatch.Elapsed.TotalSeconds
        Completed   = $true
    }
}
