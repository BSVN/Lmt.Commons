#Requires -Version 5.1
<#
    Module loader for Bsn.SystemManagement: imports the shared Bsn.Common
    helpers and dot-sources every function file under Public/ and Private/.
    The tests/ and scripts/ folders are skipped.

    Function files start with 'using module Bsn.Common', which resolves the
    module through PSModulePath at parse time; the probe below guarantees
    resolvability (sibling repo module during development, gallery copy for
    end users) BEFORE the function files are dot-sourced.
#>

Set-StrictMode -Version 'Latest'

$script:ModuleRoot = $PSScriptRoot
$script:SuspendActionScriptPath = Join-Path -Path $script:ModuleRoot -ChildPath 'scripts/Suspend-Action.ps1'

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

# Load the interop assembly through Bsn.Common's private loader (issue #15) -
# full rationale in Bsn.Host.psm1: same-version reimports reuse the loaded
# assembly, cross-version reimports get actionable guidance. The NEWEST loaded
# Bsn.Common instance wins (the session can hold several after an update).
$commonModule = Get-Module -Name 'Bsn.Common' | Sort-Object -Property Version -Descending | Select-Object -First 1
& $commonModule { param($root, $name) Import-BsnInteropAssembly -ModuleRoot $root -AssemblyName $name } $script:ModuleRoot 'Bsn.SystemManagement'

# 'using module Bsn.Common' in the function files resolves by name through
# PSModulePath at parse time - even when the module is already loaded - so make
# the repo sibling discoverable before those files are dot-sourced.
$repoSourceDirectory = Split-Path -Parent -Path $script:ModuleRoot
if ((Test-Path -LiteralPath (Join-Path -Path $repoSourceDirectory -ChildPath 'Bsn.Common/Bsn.Common.psd1')) -and
    (($env:PSModulePath -split [System.IO.Path]::PathSeparator) -notcontains $repoSourceDirectory)) {
    $env:PSModulePath = '{0}{1}{2}' -f $repoSourceDirectory, [System.IO.Path]::PathSeparator, $env:PSModulePath
}

$functionSearchPaths = @(
    (Join-Path -Path $script:ModuleRoot -ChildPath 'Public'),
    (Join-Path -Path $script:ModuleRoot -ChildPath 'Private')
) | Where-Object -FilterScript { Test-Path -LiteralPath $_ }

$functionFiles = Get-ChildItem -Path $functionSearchPaths -Filter '*.ps1' -Recurse -File -ErrorAction 'SilentlyContinue'
foreach ($functionFile in $functionFiles) {
    . $functionFile.FullName
}
