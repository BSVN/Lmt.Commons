<#
.SYNOPSIS
    Determines whether a computer name refers to the local computer.

.DESCRIPTION
    Compares the supplied name against the usual local identifiers
    ('localhost', '.', loopback addresses, the NetBIOS computer name and
    the DNS host name) so the cmdlet can run the suspend action in-process
    instead of over PowerShell remoting.
#>
function Test-BsnLocalComputer {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName
    )

    $localIdentifiers = [System.Collections.Generic.List[string]]::new()
    foreach ($identifier in @('localhost', '.', '127.0.0.1', '::1', $env:COMPUTERNAME)) {
        if ($identifier) {
            $localIdentifiers.Add($identifier)
        }
    }

    try {
        $localIdentifiers.Add([System.Net.Dns]::GetHostName())
    }
    catch {
        Write-Verbose -Message ("Could not resolve the local host name: {0}" -f $_.Exception.Message)
    }

    return ($localIdentifiers -contains $ComputerName)
}
