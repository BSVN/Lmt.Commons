<#
.SYNOPSIS
    Fails when the running PowerShell cannot load the JSON library the cast
    writer needs.

.DESCRIPTION
    Both recording engines write their cast files through the interop
    assembly's CastJson class, which uses System.Text.Json. Bsn.Host.dll is
    loaded with Add-Type -Path and resolves no dependencies itself, so each
    PowerShell edition supplies the library from where it has it:

    - PowerShell 7 binds to the System.Text.Json it ships with, and only
      when that is at least the version Bsn.Host.dll was built against. On
      a release that ships an older one, the cast writer cannot load.
    - Windows PowerShell 5.1 has none and uses the copy shipped in the
      module's lib/ folder, which is exactly that version.

    This is the PowerShell 7 half of that contract. It is checked before a
    recording starts, so an older release fails with a message that says
    what to do instead of with an "Unable to find type" error from inside
    the engine. RequiredVersion is the System.Text.Json version the module
    needs (the version of its shipped copy), AvailableVersion the one the
    running PowerShell ships.

    Kept as a separate private function so it can be unit tested with any
    pair of versions, without an old PowerShell release at hand.

.INPUTS
    None

.OUTPUTS
    None
        The function returns nothing, or throws.
#>
function Test-BsnCastJsonLibrary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [version]$RequiredVersion,

        [Parameter(Mandatory = $true)]
        [version]$AvailableVersion,

        [Parameter(Mandatory = $true)]
        [string]$PowerShellVersion
    )

    if ($AvailableVersion -lt $RequiredVersion) {
        throw ('Interactive transcripts need System.Text.Json {0} or newer to write cast files. PowerShell 7 always uses the System.Text.Json it ships with, and this session (PowerShell {1}) ships {2}. Update to a PowerShell release that ships System.Text.Json {0} or newer.' -f $RequiredVersion, $PowerShellVersion, $AvailableVersion)
    }
}
