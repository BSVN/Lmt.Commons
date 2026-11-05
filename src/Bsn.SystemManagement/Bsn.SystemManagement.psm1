#Requires -Version 5.1
<#
    Module loader for Bsn.SystemManagement: dot-sources every function file
    under Public/ and Private/. The tests/ and scripts/ folders are skipped.
#>

Set-StrictMode -Version 'Latest'

$script:ModuleRoot = $PSScriptRoot
$script:SuspendActionScriptPath = Join-Path -Path $script:ModuleRoot -ChildPath 'scripts/Suspend-Action.ps1'

$functionSearchPaths = @(
    (Join-Path -Path $script:ModuleRoot -ChildPath 'Public'),
    (Join-Path -Path $script:ModuleRoot -ChildPath 'Private')
) | Where-Object -FilterScript { Test-Path -LiteralPath $_ }

$functionFiles = Get-ChildItem -Path $functionSearchPaths -Filter '*.ps1' -Recurse -File -ErrorAction 'SilentlyContinue'
foreach ($functionFile in $functionFiles) {
    . $functionFile.FullName
}
