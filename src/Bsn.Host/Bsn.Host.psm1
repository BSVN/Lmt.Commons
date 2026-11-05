#Requires -Version 5.1
<#
    Module loader for Bsn.Host: imports the shared Bsn.Common helpers and
    dot-sources every function file under Public/ and Private/. The tests/
    folder is skipped.
#>

Set-StrictMode -Version 'Latest'

$script:ModuleRoot = $PSScriptRoot
$script:SuspendActionScriptPath = $null

if (-not (Get-Module -Name 'Bsn.Common' -ErrorAction 'SilentlyContinue')) {
    # Prefer the repo sibling module during development; fall back to the gallery copy.
    $commonManifestPath = Join-Path -Path (Split-Path -Parent -Path $script:ModuleRoot) -ChildPath 'Bsn.Common/Bsn.Common.psd1'
    if (Test-Path -LiteralPath $commonManifestPath) {
        Import-Module -Name $commonManifestPath -ErrorAction 'Stop'
    }
    else {
        Import-Module -Name 'Bsn.Common' -ErrorAction 'Stop'
    }
}

$functionSearchPaths = @(
    (Join-Path -Path $script:ModuleRoot -ChildPath 'Public'),
    (Join-Path -Path $script:ModuleRoot -ChildPath 'Private')
) | Where-Object -FilterScript { Test-Path -LiteralPath $_ }

$functionFiles = Get-ChildItem -Path $functionSearchPaths -Filter '*.ps1' -Recurse -File -ErrorAction 'SilentlyContinue'
foreach ($functionFile in $functionFiles) {
    . $functionFile.FullName
}
