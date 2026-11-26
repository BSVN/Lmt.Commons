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

    The parameters are the block's fields. Their names follow the module's
    audit export (ConvertTo-BsnAuditRecord, Export-BsnAuditLog), which reads
    the same session context back: for example ComputerName is written as
    the block's "host" and UserName as "user".

    Fields left empty are omitted rather than written as empty values.
    When no field is supplied the function returns an empty string, which
    tells the callers to leave the block out of the header.

    Output is a compact JSON object with values escaped by ConvertTo-Json,
    so it can be spliced into the header line as-is.

.PARAMETER SessionId
    GUID minted when the recording starts. Written as "session_id".

.PARAMETER RecordedBy
    Module that made the recording, for example 'bsn.host 0.3.0'. Written
    as "recorded_by".

.PARAMETER ComputerName
    Name of the machine the recorded session ran on. Written as "host".

.PARAMETER UserName
    Account that started the recording. Written as "user".

.PARAMETER ProcessId
    Process id of the PowerShell that made the recording, written as a
    JSON number under "pid". Zero (the default) omits the field.

.PARAMETER PSVersion
    Version of the PowerShell that made the recording, for example
    '7.6.9'. Written as "psversion".

.PARAMETER Edition
    Edition of the PowerShell that made the recording: 'Core' or
    'Desktop'. Written as "psedition".

.OUTPUTS
    System.String
        A compact JSON object with the supplied fields, or an empty
        string when no field was supplied.
#>
function ConvertTo-BsnCastHeaderBlock {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$SessionId = '',

        [string]$RecordedBy = '',

        [string]$ComputerName = '',

        [string]$UserName = '',

        [int]$ProcessId = 0,

        [string]$PSVersion = '',

        [string]$Edition = ''
    )

    $metadata = [ordered]@{}
    if ($SessionId) { $metadata['session_id'] = $SessionId }
    if ($RecordedBy) { $metadata['recorded_by'] = $RecordedBy }
    if ($ComputerName) { $metadata['host'] = $ComputerName }
    if ($UserName) { $metadata['user'] = $UserName }
    if ($ProcessId -gt 0) { $metadata['pid'] = $ProcessId }
    if ($PSVersion) { $metadata['psversion'] = $PSVersion }
    if ($Edition) { $metadata['psedition'] = $Edition }

    if ($metadata.Count -eq 0) {
        return ''
    }

    return (ConvertTo-Json -InputObject $metadata -Compress)
}
