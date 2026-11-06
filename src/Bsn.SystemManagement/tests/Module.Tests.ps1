BeforeAll {
    $moduleRoot = Split-Path -Parent -Path $PSScriptRoot
    # Make the repo sibling module Bsn.Common resolvable for RequiredModules validation.
    $env:PSModulePath = '{0}{1}{2}' -f (Split-Path -Parent -Path $moduleRoot), [System.IO.Path]::PathSeparator, $env:PSModulePath
    $script:ManifestPath = Join-Path -Path $moduleRoot -ChildPath 'Bsn.SystemManagement.psd1'
    Import-Module -Name $script:ManifestPath -Force -ErrorAction 'Stop'
}

Describe 'Bsn.SystemManagement manifest' {
    It 'passes manifest validation' {
        Test-ModuleManifest -Path $script:ManifestPath | Should -Not -BeNullOrEmpty
    }

    It 'exports exactly the intended public functions' {
        $manifest = Test-ModuleManifest -Path $script:ManifestPath
        ($manifest.ExportedFunctions.Keys | Sort-Object) -join ',' | Should -Be 'Suspend-Computer'
    }

    It 'stamps the interop assembly with the manifest version (issue #15)' {
        # https://github.com/BSVN/Lmt.Commons/issues/15
        # Every shipped module version must carry a distinct assembly
        # identity: with the default AssemblyVersion 1.0.0.0 in all of them,
        # Import-Module -Force after Update-Module fails with
        # FileLoadException (same identity already loaded in the process).
        $dllPath = Join-Path -Path $moduleRoot -ChildPath 'lib\Bsn.SystemManagement.dll'
        Test-Path -LiteralPath $dllPath | Should -BeTrue
        $assemblyVersion = [System.Reflection.AssemblyName]::GetAssemblyName($dllPath).Version
        $manifestVersion = (Test-ModuleManifest -Path $script:ManifestPath).Version
        $assemblyVersion.ToString(3) | Should -Be $manifestVersion.ToString()
    }
}

Describe 'Bsn.SystemManagement module' {
    It 'loads and exposes its public commands' {
        Get-Command -Name 'Suspend-Computer' -Module 'Bsn.SystemManagement' -ErrorAction 'SilentlyContinue' | Should -Not -BeNullOrEmpty
    }

    It 'ships the self-contained suspend action script' {
        Test-Path -LiteralPath (Join-Path -Path $moduleRoot -ChildPath 'scripts/Suspend-Action.ps1') | Should -BeTrue
    }

    It 'detects a known local operating system via Bsn.Common' {
        Import-Module -Name (Join-Path -Path (Split-Path -Parent -Path $moduleRoot) -ChildPath 'Bsn.Common/Bsn.Common.psd1') -Force
        @('Windows', 'Linux', 'macOS', 'Unknown') | Should -Contain ([string](Get-BsnOperatingSystem))
    }
}
