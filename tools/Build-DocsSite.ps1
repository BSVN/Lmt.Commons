<#
.SYNOPSIS
    Builds one documentation version (a git ref) into a DocFX output
    directory.

.DESCRIPTION
    Extracts docs/en-US from the given git ref ('main' or a release tag),
    builds it with the repository's pinned DocFX configuration
    (docfx.json from the current checkout), and writes the result to
    -OutputDir. Navigation entries whose pages do not exist at the ref are
    pruned, and a version switcher is injected into every page footer.
    The build inherits warningsAsErrors from docfx.json, so broken links
    or navigation entries pointing at missing pages fail the build.

    Orchestrated by tools/Build-AllDocs.ps1 (the Docs workflow); can also
    be run manually for a single version.

.PARAMETER Ref
    Git ref to build documentation for ('main' or a release tag like
    v0.2.4).

.PARAMETER OutputDir
    DocFX output directory for this version. The stable build uses the
    site root; versioned builds use site/main or site/<tag>.

.PARAMETER RepoRoot
    Repository root providing docfx.json, docs/toc.yml and the git
    history for -Ref.

.PARAMETER SiteBasePath
    GitHub Pages sub-path the site is served under (for the footer's
    absolute version-switcher links).

.PARAMETER CurrentLabel
    Footer label of THIS build, rendered bold without a link.

.PARAMETER FooterLinks
    Version switcher entries as 'label|absolute-url' strings (all
    versions, including the current one).

.EXAMPLE
    ./tools/Build-DocsSite.ps1 -Ref v0.2.4 -OutputDir site
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Ref,

    [Parameter(Mandatory = $true)]
    [string]$OutputDir,

    [string]$RepoRoot = (Get-Location).Path,

    [string]$SiteBasePath = '/Lmt.Commons',

    [string]$CurrentLabel = $Ref,

    [string[]]$FooterLinks = @()
)

$ErrorActionPreference = 'Stop'

function ConvertFrom-BsnDocsTocYaml {
    # Parses the fixed-shape navigation template (docs/toc.yml): top-level
    # entries are leaves ('- name:' + '  href:') or groups ('- name:' +
    # '  items:' with '  - name:' + '    href:' children).
    param([string]$Path)

    $entries = @()
    $current = $null
    $inItems = $false
    $child = $null
    foreach ($line in (Get-Content -Path $Path)) {
        if ($line -match '^- name:\s*(.+)$') {
            if ($null -ne $current) {
                $entries += $current
            }

            $current = @{ Name = $Matches[1].Trim(); Href = $null; Items = @() }
            $inItems = $false
            $child = $null
        }
        elseif ($line -match '^  href:\s*(.+)$') {
            $current.Href = $Matches[1].Trim()
        }
        elseif ($line -match '^  items:\s*$') {
            $inItems = $true
        }
        elseif ($inItems -and $line -match '^  - name:\s*(.+)$') {
            $child = @{ Name = $Matches[1].Trim(); Href = $null }
        }
        elseif ($inItems -and $line -match '^    href:\s*(.+)$') {
            $child.Href = $Matches[1].Trim()
            $current.Items += $child
            $child = $null
        }
    }

    if ($null -ne $current) {
        $entries += $current
    }

    return $entries
}

function Remove-BsnMissingTocEntries {
    # Keeps only navigation entries whose target page exists in the
    # version's docs; drops groups that lose all their children.
    param($Entries, [string]$DocsRoot)

    $result = @()
    foreach ($entry in $Entries) {
        if ($entry.Href) {
            if (Test-Path -LiteralPath (Join-Path -Path $DocsRoot -ChildPath $entry.Href)) {
                $result += $entry
            }
        }
        else {
            $keptChildren = @(
                $entry.Items | Where-Object { Test-Path -LiteralPath (Join-Path -Path $DocsRoot -ChildPath $_.Href) }
            )
            if ($keptChildren.Count -gt 0) {
                $result += @{ Name = $entry.Name; Href = $null; Items = $keptChildren }
            }
        }
    }

    return $result
}

function ConvertTo-BsnDocsTocYaml {
    param($Entries)

    $lines = @()
    foreach ($entry in $Entries) {
        $lines += ('- name: ' + $entry.Name)
        if ($entry.Href) {
            $lines += ('  href: ' + $entry.Href)
        }
        else {
            $lines += '  items:'
            foreach ($child in $entry.Items) {
                $lines += ('  - name: ' + $child.Name)
                $lines += ('    href: ' + $child.Href)
            }
        }
    }

    return (($lines -join "`n") + "`n")
}

function New-BsnDocsIndexContent {
    # Home page for versions older than the site, derived from the
    # surviving navigation so every link it emits is valid.
    param([string]$Ref, $Entries)

    $lines = @(
        '# Bsn PowerShell modules',
        '',
        ('Documentation for **' + $Ref + '** of the `Bsn.*` PowerShell module family'),
        'published to the [PowerShell Gallery](https://www.powershellgallery.com/) from',
        'the [BSVN/Lmt.Commons](https://github.com/BSVN/Lmt.Commons) repository.',
        '',
        'Use the version links in the page footer to switch between `main` and the',
        'released versions; this page reflects the version you are reading.',
        '',
        '## Modules',
        '',
        '| Module | Cmdlet reference |',
        '|---|---|'
    )

    foreach ($entry in ($Entries | Where-Object { -not $_.Href })) {
        $links = foreach ($child in $entry.Items) {
            '[' + $child.Name + '](' + $child.Href + ')'
        }

        $lines += ('| ' + $entry.Name + ' | ' + ($links -join ', ') + ' |')
    }

    $installCommand = 'Install-Module -Name <ModuleName> -Scope CurrentUser'
    if ($Ref -match '^v') {
        $installCommand = 'Install-Module -Name <ModuleName> -RequiredVersion ' + $Ref.Substring(1) + ' -Scope CurrentUser'
    }

    $lines += @(
        '',
        '## Install',
        '',
        '```powershell',
        $installCommand,
        '```',
        ''
    )

    return (($lines -join "`n") + "`n")
}

$stagingRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('bsn-docs-' + $Ref + '-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

try {
    # Extract docs/en-US as it exists at the ref (works for tags older than
    # the site tooling: docfx.json and the navigation template always come
    # from the current checkout, only the Markdown content is versioned).
    $archivePath = Join-Path -Path $stagingRoot -ChildPath 'docs.tar'
    & git -C $RepoRoot archive --format=tar --output=$archivePath $Ref -- docs/en-US
    if ($LASTEXITCODE -ne 0) {
        throw "git archive failed for ref '$Ref' (exit $LASTEXITCODE)."
    }

    & tar -xf $archivePath -C $stagingRoot
    if ($LASTEXITCODE -ne 0) {
        throw "tar extraction failed for ref '$Ref' (exit $LASTEXITCODE)."
    }

    $stagingDocs = Join-Path -Path $stagingRoot -ChildPath 'docs'
    if (-not (Test-Path -LiteralPath $stagingDocs)) {
        throw "Ref '$Ref' has no docs/en-US content."
    }

    # Prune the navigation template to the pages that exist at the ref.
    $tocEntries = ConvertFrom-BsnDocsTocYaml -Path (Join-Path -Path $RepoRoot -ChildPath (Join-Path 'docs' 'toc.yml'))
    $filtered = Remove-BsnMissingTocEntries -Entries $tocEntries -DocsRoot $stagingDocs
    [System.IO.File]::WriteAllText(
        (Join-Path -Path $stagingDocs -ChildPath 'toc.yml'),
        (ConvertTo-BsnDocsTocYaml -Entries $filtered))

    # Versions older than the site have no docs/index.md; synthesize one
    # from the surviving navigation so links stay valid.
    $indexPath = Join-Path -Path $stagingDocs -ChildPath 'index.md'
    if (-not (Test-Path -LiteralPath $indexPath)) {
        [System.IO.File]::WriteAllText(
            $indexPath,
            (New-BsnDocsIndexContent -Ref $Ref -Entries $filtered))
    }

    # Derive the build configuration: output directory and footer version
    # switcher are per-version; everything else (template, search,
    # warningsAsErrors) is inherited from the checked-out docfx.json.
    $outputDirItem = New-Item -ItemType Directory -Path $OutputDir -Force
    $absoluteOutput = $outputDirItem.FullName

    $footerParts = foreach ($entry in $FooterLinks) {
        $separatorIndex = $entry.IndexOf('|')
        if ($separatorIndex -lt 1) {
            throw "Invalid footer link entry '$entry' (expected 'label|url')."
        }

        $label = $entry.Substring(0, $separatorIndex)
        $url = $entry.Substring($separatorIndex + 1)
        if ($label -eq $CurrentLabel) {
            '<b>' + $label + '</b>'
        }
        else {
            '<a href="' + $url + '">' + $label + '</a>'
        }
    }

    $footerHtml = 'Docs versions: ' + ($footerParts -join ' &middot; ')

    $config = Get-Content -Raw -Path (Join-Path -Path $RepoRoot -ChildPath 'docfx.json') | ConvertFrom-Json
    $config.build.output = $absoluteOutput
    $config.build.globalMetadata._appFooter = $footerHtml
    $configJson = ConvertTo-Json -InputObject $config -Depth 32
    [System.IO.File]::WriteAllText(
        (Join-Path -Path $stagingRoot -ChildPath 'docfx.json'),
        $configJson)

    Write-Verbose "Building '$Ref' into '$absoluteOutput'."
    # Run from the repo root so the dotnet local-tool manifest
    # (.config/dotnet-tools.json) is discovered; docfx resolves the
    # content paths relative to the staging config file itself.
    $configPath = Join-Path -Path $stagingRoot -ChildPath 'docfx.json'
    Push-Location -Path $RepoRoot
    try {
        & dotnet docfx $configPath
        if ($LASTEXITCODE -ne 0) {
            throw "docfx build failed for '$Ref' (exit $LASTEXITCODE)."
        }
    }
    finally {
        Pop-Location
    }
}
finally {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction 'SilentlyContinue'
}
