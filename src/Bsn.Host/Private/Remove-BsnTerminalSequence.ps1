<#
.SYNOPSIS
    Strips terminal escape sequences from a raw VT stream chunk.

.DESCRIPTION
    Pure helper (no console interaction) used by the cast-to-transcript
    pipeline (ConvertTo-BsnTranscript). Removes ANSI/VT escape sequences
    from recorded terminal output while leaving text content and the
    cursor-motion control characters that carry text semantics intact:

    - CSI sequences (ESC [ ... final byte), including private modes,
      colon subparameters and space-intermediate forms.
    - OSC, DCS, SOS, PM and APC strings terminated by BEL or ST (ESC \);
      truncated (unterminated) strings are stripped to the end of input.
    - Two- and three-byte escape sequences (charset selection ESC ( B,
      keypad modes ESC = / ESC >, cursor save/restore ESC 7 / ESC 8, ...).
    - Stand-alone C0 control characters that carry no text content
      (BEL, NUL, vertical tab, form feed, ENQ, ...).

    Kept control characters: line feed (0x0A), carriage return (0x0D),
    backspace (0x08) and tab (0x09) - the characters whose cursor-motion
    semantics ConvertTo-BsnPlainText resolves into plain text.
#>
function Remove-BsnTerminalSequence {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure text transformation; does not change system state.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    # One alternation, ordered so the string types (OSC/DCS/SOS/PM/APC)
    # match BEFORE the generic two-byte escape branch: their introducing
    # byte (']', 'P', ...) would otherwise be read as a sequence final
    # byte and the payload text would leak into the transcript. '\z' also
    # strips a truncated (unterminated) string to the end of the input.
    $escapePattern = "\x1B(?:\[[\x30-\x3F]*[\x20-\x2F]*[\x40-\x7E]|\][^\x07\x1B]*(?:\x07|\x1B\\|\z)|[PX^_][^\x07\x1B]*(?:\x07|\x1B\\|\z)|[\x20-\x2F]*[\x30-\x7E])"

    $stripped = [regex]::Replace($Text, $escapePattern, '')

    # C0 controls that carry no text content. Line feed, carriage return,
    # backspace and tab are kept (see .DESCRIPTION).
    $stripped = [regex]::Replace($stripped, '[\x00-\x07\x0B\x0C\x0E-\x1F\x7F]', '')

    return $stripped
}
