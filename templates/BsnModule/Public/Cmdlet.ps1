<#
.SYNOPSIS
    TODO: Describe what <%= $PLASTER_PARAM_CmdletName %> does.

.DESCRIPTION
    TODO: Describe <%= $PLASTER_PARAM_CmdletName %> in detail.

.EXAMPLE
    <%= $PLASTER_PARAM_CmdletName %>

    TODO: Describe the example.

.NOTES
    Part of <%= $PLASTER_PARAM_ModuleName %>.
#>
function <%= $PLASTER_PARAM_CmdletName %> {
    [CmdletBinding()]
    param(
        # TODO: Define parameters.
        [Parameter(ValueFromPipeline = $true)]
        [string]$Name
    )

    process {
        # TODO: Implement <%= $PLASTER_PARAM_CmdletName %>.
        Write-Verbose -Message ('Not implemented yet: {0}' -f $Name)
    }
}
