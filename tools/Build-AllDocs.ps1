# Builds the versioned documentation site for the Bsn.* family.

# Build-DocsSite.ps1: build ONE documentation version (git ref) with DocFX.
# Build-AllDocs.ps1:   orchestrate all versions (main + release tags).

# Called by the Docs workflow and runnable locally; both scripts write the
# final site tree that the workflow uploads to GitHub Pages, where:
#   /              = docs of the latest release tag (stable; the /en-US/
#                    HelpUri targets of released modules resolve here)
#   /main/         = development documentation
#   /vX.Y.Z/       = one documentation set per release tag

[CmdletBinding()]
param(
    [string]$RepoRoot = (Get-Location).Path,
    [string]$SiteOutputDir = 'site',
    [string]$SiteBasePath = '/Lmt.Commons',
    [switch]$MainOnly
)

$ErrorActionPreference = 'Stop'

$siteRoot = Join-Path -Path $RepoRoot -ChildPath $SiteOutputDir

# Release tags that actually contain docs/en-US content, newest first.
$tagList = @()
if (-not $MainOnly) {
    $tagList = @(
        git -C $RepoRoot tag --list 'v*' --sort=-v:refname | ForEach-Object { $_.Trim() } |
            Where-Object { @(git -C $RepoRoot ls-tree -r --name-only $_ -- docs/en-US).Count -gt 0 }
    )
}

$stableTag = $null
if ($tagList.Count -gt 0) {
    $stableTag = $tagList[0]
}

# Version switcher for every page footer. Absolute URLs (under the Pages
# sub-path) so the strip works at any page depth. The entry whose label
# matches -CurrentLabel is rendered bold without a link by the build script.
$footerLinks = @('main|' + $SiteBasePath + '/main/')
if ($stableTag) {
    $footerLinks += ($stableTag + ' (stable)|' + $SiteBasePath + '/')
    foreach ($tag in ($tagList | Where-Object { $_ -ne $stableTag })) {
        $footerLinks += ($tag + '|' + $SiteBasePath + '/' + $tag + '/')
    }
}

$buildScript = Join-Path -Path $PSScriptRoot -ChildPath 'Build-DocsSite.ps1'

Write-Host 'Building docs for main -> site/main'
& $buildScript -Ref 'origin/main' -OutputDir (Join-Path $siteRoot 'main') `
    -RepoRoot $RepoRoot -SiteBasePath $SiteBasePath `
    -CurrentLabel 'main' -FooterLinks $footerLinks

if ($MainOnly) {
    return
}

if (-not $stableTag) {
    Write-Warning 'No release tags with docs/en-US content found; built main only.'
    return
}

# Stable: latest release tag at the site root, so the /en-US/<Cmdlet>.html
# HelpUri targets keep serving the latest RELEASED documentation.
Write-Host "Building docs for $stableTag (stable) -> site root"
& $buildScript -Ref $stableTag -OutputDir $siteRoot `
    -RepoRoot $RepoRoot -SiteBasePath $SiteBasePath `
    -CurrentLabel "$stableTag (stable)" -FooterLinks $footerLinks

foreach ($tag in ($tagList | Where-Object { $_ -ne $stableTag })) {
    Write-Host "Building docs for $tag -> site/$tag"
    & $buildScript -Ref $tag -OutputDir (Join-Path $siteRoot $tag) `
        -RepoRoot $RepoRoot -SiteBasePath $SiteBasePath `
        -CurrentLabel $tag -FooterLinks $footerLinks
}

# Canonical version list for the header switcher (and any future consumer).
$versionEntries = @(
    [pscustomobject]@{ label = 'main'; url = ($SiteBasePath + '/main/') }
)
if ($stableTag) {
    $versionEntries += [pscustomobject]@{ label = ($stableTag + ' (stable)'); url = ($SiteBasePath + '/') }
    foreach ($tag in ($tagList | Where-Object { $_ -ne $stableTag })) {
        $versionEntries += [pscustomobject]@{ label = $tag; url = ($SiteBasePath + '/' + $tag + '/') }
    }
}

[System.IO.File]::WriteAllText(
    (Join-Path -Path $siteRoot -ChildPath 'versions.json'),
    (ConvertTo-Json -InputObject $versionEntries -Compress))
