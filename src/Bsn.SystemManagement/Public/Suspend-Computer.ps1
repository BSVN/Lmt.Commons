<#
.SYNOPSIS
    Puts one or more computers into a low-power state (sleep or hibernate).

.DESCRIPTION
    Suspend-Computer completes the *-Computer power lifecycle family
    (Stop-Computer, Restart-Computer) with the missing suspend state.

    On Windows the cmdlet calls the documented SetSuspendState API from
    powrprof.dll via P/Invoke. On Linux it invokes systemctl (or loginctl)
    with the suspend or hibernate action. On macOS it invokes pmset sleepnow.
    Non-systemd Linux systems are not supported yet.

    Without parameters, the cmdlet suspends the local computer to sleep.
    Use -Hibernate to hibernate instead (Windows and Linux only).
    Use -ComputerName to suspend remote computers over PowerShell remoting
    (WinRM or SSH); the module does not need to be installed on the remote
    computer.

    Use -After to delay the suspension: the countdown runs on the TARGET
    computer, so a remote machine suspends N seconds after the command
    reaches it. While the countdown is running, press Ctrl+C to cancel the
    pending suspension.

.PARAMETER ComputerName
    Specifies the target computers. The default is the local computer.
    Accepts pipeline input. Remote computers require PowerShell remoting
    (WinRM or SSH) to be enabled.

.PARAMETER Hibernate
    Hibernates the target (S4) instead of entering sleep (S3 / Modern
    Standby). Not supported on macOS. On Linux, hibernation must be
    available (the 'disk' power state in /sys/power/state).

.PARAMETER Force
    Suspends without prompting for confirmation and requests a forced
    (critical) suspend so the system does not wait for applications.

.PARAMETER After
    Suspends the target after the specified number of seconds have elapsed
    on the TARGET computer (the countdown starts when the command reaches
    it). The default (0) suspends immediately. While the countdown runs,
    press Ctrl+C to cancel the pending suspension.

.INPUTS
    System.String
        Computer names from the pipeline.

.OUTPUTS
    None

.EXAMPLE
    Suspend-Computer -WhatIf

    Shows what would happen without suspending anything.

.EXAMPLE
    Suspend-Computer

    Prompts for confirmation, then puts the local computer to sleep.

.EXAMPLE
    Suspend-Computer -Hibernate -Force

    Hibernates the local computer immediately, without a confirmation prompt.

.EXAMPLE
    Suspend-Computer -ComputerName WORKSTATION-07, WORKSTATION-12 -Confirm:$false

    Suspends two remote computers over PowerShell remoting without a prompt.

.EXAMPLE
    Suspend-Computer -After 60

    Suspends the local computer after 60 seconds, leaving a minute to save
    your work.

.EXAMPLE
    Suspend-Computer -ComputerName MEDIA-01 -After 300 -Confirm:$false

    Suspends the remote computer MEDIA-01 five minutes after the command
    reaches it.

.NOTES
    Implements the community request tracked in
    https://github.com/PowerShell/PowerShell/issues/28164. The PowerShell
    Cmdlets Working Group recommended this functionality be delivered as a
    community module on the PowerShell Gallery.

    The '-After' delay implements the request tracked in
    https://github.com/BSVN/Lmt.Commons/issues/17.

.LINK
    https://bsvn.github.io/Lmt.Commons/en-US/Suspend-Computer.html
#>
function Suspend-Computer {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$ComputerName,

        [switch]$Hibernate,

        [switch]$Force,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$After = 0
    )

    begin {
        $targetComputers = [System.Collections.Generic.List[string]]::new()
    }

    process {
        foreach ($computerName in $ComputerName) {
            $targetComputers.Add($computerName)
        }
    }

    end {
        if ($targetComputers.Count -eq 0) {
            $targetComputers.Add('localhost')
        }

        foreach ($computer in $targetComputers) {
            $powerState = if ($Hibernate.IsPresent) { 'hibernate' } else { 'sleep' }
            $shouldProcessDescription = if ($After -gt 0) {
                ("Enter the '{0}' power state after {1} seconds" -f $powerState, $After)
            }
            else {
                ("Enter the '{0}' power state" -f $powerState)
            }

            if ($Force.IsPresent -or $PSCmdlet.ShouldProcess($computer, $shouldProcessDescription)) {
                # Grace period for the '-After' delay (issue #17): the
                # countdown runs before the dispatch and Ctrl+C during it
                # cancels the pending suspension. For remote computers the
                # target suspends as soon as the command reaches it.
                Wait-BsnSuspendGracePeriod -Seconds $After

                try {
                    if (Test-BsnLocalComputer -ComputerName $computer) {
                        Invoke-BsnLocalSuspend -Hibernate:$Hibernate.IsPresent -Force:$Force.IsPresent
                    }
                    else {
                        # Ship the self-contained action script to the remote machine;
                        # the module itself does not need to be installed remotely.
                        $null = Invoke-Command -ComputerName $computer -FilePath $script:SuspendActionScriptPath -ArgumentList @([bool]$Hibernate.IsPresent, [bool]$Force.IsPresent) -ErrorAction 'Stop'
                    }
                }
                catch {
                    Write-Error -Exception $_.Exception -ErrorId 'SuspendComputerFailed' -Category 'OperationStopped' -TargetObject $computer
                }
            }
        }
    }
}
