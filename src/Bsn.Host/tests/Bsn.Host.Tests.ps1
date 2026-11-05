BeforeAll {
    $moduleRoot = Split-Path -Parent -Path $PSScriptRoot
    $script:ManifestPath = Join-Path -Path $moduleRoot -ChildPath 'Bsn.Host.psd1'
    Import-Module -Name $script:ManifestPath -Force -ErrorAction 'Stop'
}

Describe 'Bsn.Host manifest' {
    It 'passes manifest validation' {
        Test-ModuleManifest -Path $script:ManifestPath | Should -Not -BeNullOrEmpty
    }

    It 'exports exactly the intended public functions' {
        $manifest = Test-ModuleManifest -Path $script:ManifestPath
        ($manifest.ExportedFunctions.Keys | Sort-Object) -join ',' | Should -Be 'Start-InteractiveTranscript'
    }
}

Describe 'Bsn.Host module' {
    It 'loads and exposes its public commands' {
        Get-Command -Name 'Start-InteractiveTranscript' -Module 'Bsn.Host' -ErrorAction 'SilentlyContinue' | Should -Not -BeNullOrEmpty
    }
}

