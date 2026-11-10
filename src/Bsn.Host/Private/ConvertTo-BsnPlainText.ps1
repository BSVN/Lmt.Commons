<#
.SYNOPSIS
    Renders a raw terminal output stream as plain text.

.DESCRIPTION
    Pure helper (no console interaction) that turns a recorded terminal
    output stream - the concatenation of a cast file's 'o' events - into
    the plain text a reader would assign to that session. This is the
    line-oriented rendering used by tools such as 'ansi2txt' and asciinema
    when a terminal stream is flattened to text:

    1. Escape sequences are stripped (Remove-BsnTerminalSequence).
    2. Carriage-return overtype and backspace are resolved line by line:
       a carriage return resets the write position to column 0 so the
       following characters overwrite earlier ones (progress bars collapse
       to their final frame; leftover characters from a longer previous
       line remain, exactly as they would have stayed on a real terminal),
       and a backspace moves the write position one column back.

    Tab characters are kept verbatim; in the overtype model they advance
    the write position by one column, not by their terminal width.

    Line-oriented shell sessions convert cleanly. Full-screen TUI
    applications redraw the whole screen with cursor addressing and
    produce columnar residue - documented limitation; the .cast file
    remains the exact evidence and can be replayed with
    Show-InteractiveTranscript.
#>
function ConvertTo-BsnPlainText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $stripped = Remove-BsnTerminalSequence -Text $Text
    $lines = $stripped.Split([char]10)
    $resolved = [System.Collections.Generic.List[string]]::new()
    $cursorControlCharacters = [char[]]@([char]8, [char]13)

    foreach ($line in $lines) {
        # Fast path: most lines carry no carriage return or backspace.
        if ($line.IndexOfAny($cursorControlCharacters) -lt 0) {
            $resolved.Add($line)
            continue
        }

        $builder = [System.Text.StringBuilder]::new($line.Length)
        $cursor = 0
        foreach ($character in $line.ToCharArray()) {
            if ($character -eq [char]13) {
                # Carriage return: the next characters overwrite from column 0.
                $cursor = 0
            }
            elseif ($character -eq [char]8) {
                # Backspace: move the write position one column back.
                if ($cursor -gt 0) {
                    $cursor--
                }
            }
            elseif ($cursor -lt $builder.Length) {
                $builder[$cursor] = $character
                $cursor++
            }
            else {
                [void]$builder.Append($character)
                $cursor++
            }
        }
        $resolved.Add($builder.ToString())
    }

    return ($resolved -join "`n")
}
