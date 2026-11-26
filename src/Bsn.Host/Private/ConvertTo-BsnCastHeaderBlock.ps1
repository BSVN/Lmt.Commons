<#
.SYNOPSIS
    Serializes the capture-time audit metadata into the cast header's
    "bsn" block.

.DESCRIPTION
    Pure helper (no console interaction) and the single definition of the
    bsn header block's shape. Both recording engines build the block
    through it - the Windows engine hands the result to the compiled
    CastWriter, the Unix engine to ConvertTo-BsnAsciicast - so a recording
    always carries the same keys regardless of the platform it was made
    on.

    The parameters are the block's fields under the names
    ConvertTo-BsnTranscript exposes for reading them back (Machine maps to
    the block's "host", Username to "user" and Edition to "psedition").
    Fields left empty are omitted rather than written as empty values.
    When no field is supplied the function returns an empty string, which
    tells the callers to leave the block out of the header.

    Output is a compact JSON object with values escaped by ConvertTo-Json,
    so it can be spliced into the header line as-is.
#>
function ConvertTo-BsnCastHeaderBlock {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # GUID minted when the recording starts.
        [string]$SessionId = '',

        # Module that made the recording, for example 'bsn.host 0.3.0'.
        [string]$RecordedBy = '',

        # Name of the machine the recorded session ran on.
        [string]$Machine = '',

        # Account that started the recording.
        [string]$Username = '',

        # Process id of the PowerShell that made the recording. Zero
        # (the default) omits the field.
        [int]$ProcessId = 0,

        [string]$PSVersion = '',

        [string]$Edition = ''
    )

    $metadata = [ordered]@{}
    if ($SessionId) { $metadata['session_id'] = $SessionId }
    if ($RecordedBy) { $metadata['recorded_by'] = $RecordedBy }
    if ($Machine) { $metadata['host'] = $Machine }
    if ($Username) { $metadata['user'] = $Username }
    if ($ProcessId -gt 0) { $metadata['pid'] = $ProcessId }
    if ($PSVersion) { $metadata['psversion'] = $PSVersion }
    if ($Edition) { $metadata['psedition'] = $Edition }

    if ($metadata.Count -eq 0) {
        return ''
    }

    return (ConvertTo-Json -InputObject $metadata -Compress)
}
