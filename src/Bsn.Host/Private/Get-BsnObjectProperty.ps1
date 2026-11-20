<#
.SYNOPSIS
    Reads an optional property from a parsed cast header object.

.DESCRIPTION
    Pure helper (no console interaction): returns the value of a
    PSCustomObject property or $null when the property does not exist.
    Cast headers carry optional keys (timestamp, command, env, term,
    width, height, ...) and the module runs under Set-StrictMode, where a
    direct reference to a non-existent property is a terminating error -
    the decoder must stay tolerant so recorder-side metadata additions
    cannot break transcript conversion.
#>
function Get-BsnObjectProperty {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }

    return $null
}
