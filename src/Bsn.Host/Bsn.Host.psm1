#Requires -Version 5.1
<#
    Module loader for Bsn.Host: imports the shared Bsn.Common helpers and
    dot-sources every function file under Public/ and Private/. The tests/
    folder is skipped.

    Function files start with 'using module Bsn.Common', which resolves the
    module through PSModulePath at parse time; the probe below guarantees
    resolvability (sibling repo module during development, gallery copy for
    end users) BEFORE the function files are dot-sourced.
#>

Set-StrictMode -Version 'Latest'

enum BsnRecordingFormat {
    Asciicast
    Gif
    WebM
    Mp4
}

# Header frame of ConvertTo-BsnTranscript output:
#   Standard - Start-Transcript-like header; engine-derived fields that a
#              cast cannot record (Username, Machine, PSVersion, ...) are
#              blank unless supplied via parameters.
#   Bsn      - adds the audit frame: deterministic session id, recorded-by
#              version, terminal size, cast file path, cast SHA-256 and
#              the v3 exit code.
enum BsnTranscriptHeaderMode {
    Standard
    Bsn
}

enum BsnTranscriptRenderMode {
    # Line-oriented plain-text rendering: strip CSI/OSC/VT escape
    # sequences and resolve carriage-return overtype and backspace (the
    # way tools such as ansi2txt flatten terminal streams). Line-oriented
    # shell sessions convert cleanly; full-screen TUI redraws leave
    # columnar residue. A full VT screen-buffer emulation tier may join
    # later - this enum reserves that value space.
    Strip
}

# Output encoding of the transcript file: UTF8 (the default) is written
# without BOM; the Unicode variants are written with a BOM. Real
# Start-Transcript files are UTF-16LE (Windows PowerShell 5.1) or UTF-8
# (PowerShell 7); the converter standardizes on UTF-8 across editions.
enum BsnTranscriptEncoding {
    UTF8
    ASCII
    Unicode
    BigEndianUnicode
    UTF32
}

$script:ModuleRoot = $PSScriptRoot

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


# Load the interop assembly through Bsn.Common's private loader instead of the
# manifest's RequiredAssemblies (issue #15): a same-version reimport
# (Import-Module -Force) reuses the loaded assembly, and a cross-version
# reimport (after Update-Module) fails with actionable guidance instead of a
# raw FileLoadException. Pick the NEWEST loaded Bsn.Common: after an update
# the session may hold the old gallery copy and the newly required version
# side by side, and invoking an array of module infos would stringify into a
# bogus command. The engine types resolve at call time, so loading after the
# function files are dot-sourced matches the RequiredAssemblies timing.
$commonModule = Get-Module -Name 'Bsn.Common' | Sort-Object -Property Version -Descending | Select-Object -First 1
& $commonModule { param($root, $name) Import-BsnInteropAssembly -ModuleRoot $root -AssemblyName $name } $script:ModuleRoot 'Bsn.Host'
