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

    It 'exposes the online-help HelpUri for every public function' {
        Get-Command -Module 'Bsn.SystemManagement' | ForEach-Object {
            $_.HelpUri | Should -Be ('https://bsvn.github.io/Lmt.Commons/en-US/' + $_.Name + '.html')
        }
    }

    It 'stamps the interop assembly with the manifest version (issue #15)' {
        # Same guard as Bsn.Host (issue #15): the DLL's AssemblyVersion must
        # follow the manifest, otherwise the loader's version checks cannot
        # distinguish releases.
        $dllPath = Join-Path -Path $moduleRoot -ChildPath 'lib/Bsn.SystemManagement.dll'
        Test-Path -LiteralPath $dllPath | Should -BeTrue
        [System.Reflection.AssemblyName]::GetAssemblyName($dllPath).Version.ToString(3) |
            Should -Be (Test-ModuleManifest -Path $script:ManifestPath).Version.ToString()
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
