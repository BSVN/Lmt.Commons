<#
.SYNOPSIS
    Selects the bytes of the recorded session's output from a script(1)
    log.

.DESCRIPTION
    script(1) may write two messages of its own into the log it keeps for
    a recording: a first line

        Script started on <date> [COMMAND="..."]

    and, after the session's output, a line

        Script done on <date> [COMMAND_EXIT_CODE="N"]

    util-linux writes both into its output log (script --log-out) even in
    quiet mode. macOS's BSD script(1) leaves both out in quiet mode, which
    the engine always asks for.

    The messages are not what the recorded session printed, so they must
    not reach the cast. With util-linux they do more damage than that. Its
    timing log (script --log-timing) covers the session's output only,
    while its output log holds the start message in front of that output
    and the done message behind it. Pairing the timing entries with the
    file from its first byte therefore timed the start message, and left
    the whole session as one untimed block at the end of the cast.

    This function returns the bytes of the session's output alone:

    - A first line beginning with "Script started on" is left out. When
      TimedBytes is given, it is only left out when the file holds more
      bytes than the timing log covers.
    - A last line beginning with "Script done on" is left out, together
      with the line break script(1) writes in front of it.
    - Without a timing log there is nothing to tell a message from a line
      of the session that merely reads like one, so the ends are left out
      only when both read like messages.

    A log without messages comes back unchanged.

.PARAMETER Bytes
    The recorded output log.

.PARAMETER TimedBytes
    The number of bytes the timing log covers, or -1 (the default) when
    there is no timing log.

.OUTPUTS
    [byte[]]
        The bytes of the recorded session's output.
#>
function Select-BsnSessionOutput {
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes,

        [int]$TimedBytes = -1
    )

    $startMessage = 'Script started on'
    $doneMessage = 'Script done on'
    $lineFeed = [byte]10
    $ascii = [System.Text.Encoding]::ASCII

    $length = $Bytes.Length
    if ($length -eq 0) {
        return ,([byte[]]@())
    }

    # Does the first line read like the start message?
    $startIsMessage = ($length -ge $startMessage.Length) -and
        ($ascii.GetString($Bytes, 0, $startMessage.Length) -ceq $startMessage)
    $startIsMessage = $startIsMessage -and (($TimedBytes -lt 0) -or ($TimedBytes -lt $length))

    # Where does the last line begin, and does it read like the done
    # message? A message is short: where the last line begins is looked
    # for no further back than any message can be long.
    $lastLineStart = -1
    $lastByte = $length - 1
    if ($Bytes[$lastByte] -eq $lineFeed) {
        # The file ends with a line break after the message.
        $lastByte--
    }
    for ($index = $lastByte; $index -ge 0; $index--) {
        if ($Bytes[$index] -eq $lineFeed) {
            $lastLineStart = $index + 1
            break
        }
        if ($lastByte - $index -ge 512) {
            break
        }
    }
    if (($lastLineStart -lt 0) -and ($lastByte -lt 512)) {
        # A single line: it begins where the file begins.
        $lastLineStart = 0
    }
    $doneIsMessage = ($lastLineStart -ge 0) -and ($lastByte - $lastLineStart + 1 -ge $doneMessage.Length) -and
        ($ascii.GetString($Bytes, $lastLineStart, $doneMessage.Length) -ceq $doneMessage)

    if ($TimedBytes -lt 0) {
        # Without a timing log, only both ends together mark the messages.
        $doneIsMessage = $startIsMessage -and $doneIsMessage
        $startIsMessage = $doneIsMessage
    }

    $start = 0
    if ($startIsMessage) {
        $firstLineBreak = [System.Array]::IndexOf($Bytes, $lineFeed)
        if ($firstLineBreak -lt 0) {
            # The whole file is the message.
            $start = $length
        }
        else {
            $start = $firstLineBreak + 1
        }
    }

    $end = $length
    if ($doneIsMessage -and ($lastLineStart -ge $start)) {
        $end = $lastLineStart
        if (($end -gt $start) -and ($Bytes[$end - 1] -eq $lineFeed)) {
            # script(1) breaks the line in front of its message.
            $end--
        }
    }

    if (($start -eq 0) -and ($end -eq $length)) {
        return ,$Bytes
    }
    $count = $end - $start
    if ($count -le 0) {
        return ,([byte[]]@())
    }
    $output = [byte[]]::new($count)
    [System.Array]::Copy($Bytes, $start, $output, 0, $count)
    return ,$output
}
