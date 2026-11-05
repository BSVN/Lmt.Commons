#Requires -Version 5.1
<#
    Module loader for Bsn.Common: dot-sources every function file under
    Public/. Private/ is skipped. The shared BsnOperatingSystem enum type
    ships in the compiled assembly (lib/Bsn.Common.dll) loaded via the
    manifest's RequiredAssemblies, so it resolves module-internally and
    cross-module alike.
#>

Set-StrictMode -Version 'Latest'

$script:ModuleRoot = $PSScriptRoot

$functionSearchPaths = @(
    (Join-Path -Path $script:ModuleRoot -ChildPath 'Public'),
    (Join-Path -Path $script:ModuleRoot -ChildPath 'Private')
) | Where-Object -FilterScript { Test-Path -LiteralPath $_ }

$functionFiles = Get-ChildItem -Path $functionSearchPaths -Filter '*.ps1' -Recurse -File -ErrorAction 'SilentlyContinue'
foreach ($functionFile in $functionFiles) {
    . $functionFile.FullName
}
