<#
.SYNOPSIS
    Sends framed syslog messages to a syslog server.

.DESCRIPTION
    Thin transport used by the Syslog target of Export-BsnAuditLog - no
    record logic, only sockets. One call opens the connection, sends every
    frame and closes it:

    - TLS (default): TcpClient + SslStream (RFC 5425), identical API on
      Windows PowerShell 5.1 and PowerShell 7.
    - TCP: plain TCP, explicit opt-in for lab environments.
    - UDP: one datagram per frame, explicit opt-in for lab environments.

    TCP and TLS frames carry RFC 6587 octet-counting framing (byte count,
    a single space, then the message) - the only reliable framing on
    streams where newlines can appear inside escaped payloads. UDP frames
    are sent as the raw line. Any socket or TLS failure is a terminating
    error (the audit "forwarder failure = err" condition of issue #21).
#>
function Send-BsnAuditSyslog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Frames,

        [Parameter(Mandatory = $true)]
        [string]$Server,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$Port,

        [ValidateSet('TLS', 'TCP', 'UDP')]
        [string]$Transport = 'TLS'
    )

    $utf8 = [System.Text.Encoding]::UTF8

    if ($Transport -eq 'UDP') {
        $udpClient = [System.Net.Sockets.UdpClient]::new()
        try {
            foreach ($frame in $Frames) {
                $datagram = $utf8.GetBytes($frame)
                [void]$udpClient.Send($datagram, $datagram.Length, $Server, $Port)
            }
        }
        finally {
            $udpClient.Dispose()
        }
        return
    }

    $tcpClient = [System.Net.Sockets.TcpClient]::new()
    try {
        $tcpClient.Connect($Server, $Port)
        $stream = $tcpClient.GetStream()
        if ($Transport -eq 'TLS') {
            $tlsStream = [System.Net.Security.SslStream]::new($stream, $false)
            $tlsStream.AuthenticateAsClient($Server)
            $stream = $tlsStream
        }
        try {
            foreach ($frame in $Frames) {
                $frameBytes = $utf8.GetBytes($frame)
                $prefixBytes = [System.Text.Encoding]::ASCII.GetBytes(('{0} ' -f $frameBytes.Length))
                $stream.Write($prefixBytes, 0, $prefixBytes.Length)
                $stream.Write($frameBytes, 0, $frameBytes.Length)
                $stream.Flush()
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $tcpClient.Dispose()
    }
}
