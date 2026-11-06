BeforeAll {
    $moduleRoot = Split-Path -Parent -Path (Split-Path -Parent -Path $PSScriptRoot)
    # Make the repo sibling module Bsn.Common resolvable for RequiredModules validation.
    $env:PSModulePath = '{0}{1}{2}' -f (Split-Path -Parent -Path $moduleRoot), [System.IO.Path]::PathSeparator, $env:PSModulePath
    $script:ManifestPath = Join-Path -Path $moduleRoot -ChildPath 'Bsn.Host.psd1'
    # The module's DLL may already be loaded in this process (e.g., by PSScriptAnalyzer
    # analyzing the manifest), which makes Import-Module fail with FileLoadException.
    # Fall back to importing the psm1 directly - the assembly is already in memory.
    try {
        Import-Module -Name $script:ManifestPath -Force -ErrorAction 'Stop'
    }
    catch [System.IO.FileLoadException] {
        Import-Module -Name (Join-Path $moduleRoot 'Bsn.Host.psm1') -Force -ErrorAction 'Stop'
    }
}

Describe 'Bsn.Host manifest' {
    It 'passes manifest validation' {
        Test-ModuleManifest -Path $script:ManifestPath | Should -Not -BeNullOrEmpty
    }

    It 'exports exactly the intended public functions' {
        $manifest = Test-ModuleManifest -Path $script:ManifestPath
        ($manifest.ExportedFunctions.Keys | Sort-Object) -join ',' | Should -Be 'Show-InteractiveTranscript,Start-InteractiveTranscript,Stop-InteractiveTranscript'
    }

    It 'stamps the interop assembly with the manifest version (issue #15)' {
        # https://github.com/BSVN/Lmt.Commons/issues/15
        # Every shipped module version must carry a distinct assembly
        # identity: with the default AssemblyVersion 1.0.0.0 in all of them,
        # Import-Module -Force after Update-Module fails with
        # FileLoadException (same identity already loaded in the process).
        $dllPath = Join-Path -Path $moduleRoot -ChildPath 'lib\Bsn.Host.dll'
        Test-Path -LiteralPath $dllPath | Should -BeTrue
        $assemblyVersion = [System.Reflection.AssemblyName]::GetAssemblyName($dllPath).Version
        $manifestVersion = (Test-ModuleManifest -Path $script:ManifestPath).Version
        $assemblyVersion.ToString(3) | Should -Be $manifestVersion.ToString()
    }
}

Describe 'Bsn.Host module' {
    It 'loads and exposes its public commands' {
        foreach ($commandName in @('Start-InteractiveTranscript', 'Stop-InteractiveTranscript', 'Show-InteractiveTranscript')) {
            Get-Command -Name $commandName -Module 'Bsn.Host' -ErrorAction 'SilentlyContinue' | Should -Not -BeNullOrEmpty
        }
    }
}

