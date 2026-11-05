<#
.SYNOPSIS
    Scaffolds a new Bsn.* module in this repository using Plaster.

.DESCRIPTION
    Thin wrapper around Invoke-Plaster that runs the templates/BsnModule
    template so every module in this repository is created with the same
    layout (manifest, loader, Public/Private commands, help topic, tests).
    Installs the Plaster module from the PowerShell Gallery when missing.

.EXAMPLE
    ./tools/New-BsnModule.ps1 -ModuleName Bsn.Example -CmdletName Get-Example -Description 'Example commands.'

.EXAMPLE
    ./tools/New-BsnModule.ps1 -ModuleName Bsn.Example -CmdletName Get-Example -Description 'Example commands.' -Version 0.2.0 -Author 'BSVN' -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^Bsn\.[A-Z][A-Za-z0-9]{1,50}$')]
    [string]$ModuleName,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Z][a-z]+-[A-Z][A-Za-z0-9]+$')]
    [string]$CmdletName,

    [Parameter(Mandatory = $true)]
    [string]$Description,

    [string]$Version = '0.1.0',

    [string]$Author = 'BSVN',

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Warn early when the chosen verb is not approved by PowerShell.
$verb = ($CmdletName -split '-', 2)[0]
if (-not (Get-Verb | Where-Object -FilterScript { $_.Verb -eq $verb })) {
    Write-Warning -Message ("'{0}' is not an approved PowerShell verb. See Get-Verb for the approved list." -f $verb)
}

$repoRoot = Split-Path -Parent -Path $PSScriptRoot
$templatePath = Join-Path -Path $repoRoot -ChildPath 'templates/BsnModule'

$existingManifest = Join-Path -Path $repoRoot -ChildPath ('src/{0}/{0}.psd1' -f $ModuleName)
if ((Test-Path -LiteralPath $existingManifest) -and -not $Force.IsPresent) {
    throw ("Module '{0}' already exists at '{1}'. Use -Force to overwrite." -f $ModuleName, $existingManifest)
}

if (-not (Get-Module -Name Plaster -ListAvailable)) {
    Write-Host 'Installing the Plaster module from the PowerShell Gallery...'
    Install-Module -Name Plaster -Scope 'CurrentUser' -Force
}
Import-Module -Name Plaster -ErrorAction 'Stop'

$plasterParameters = @{
    TemplatePath    = $templatePath
    DestinationPath = $repoRoot
    ModuleName      = $ModuleName
    CmdletName      = $CmdletName
    Description     = $Description
    Version         = $Version
    Author          = $Author
    NoLogo          = $true
}
if ($Force.IsPresent) {
    $plasterParameters['Force'] = $true
}

Invoke-Plaster @plasterParameters

Write-Host ''
Write-Host ("Module '{0}' scaffolded." -f $ModuleName)
Write-Host 'Next steps:'
Write-Host ("  1. Implement the command in src/{0}/Public/ and helpers in src/{0}/Private/." -f $ModuleName)
Write-Host ("  2. Adjust the Pester tests in src/{0}/tests/." -f $ModuleName)
Write-Host '  3. Run ./build.ps1 -Task Analyze, Test'
Write-Host '  4. Bump the module version, then push a v* git tag to publish to the PowerShell Gallery.'
