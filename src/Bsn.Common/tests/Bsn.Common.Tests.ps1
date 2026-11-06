BeforeAll {
    $moduleRoot = Split-Path -Parent -Path $PSScriptRoot
    $script:ManifestPath = Join-Path -Path $moduleRoot -ChildPath 'Bsn.Common.psd1'
    Import-Module -Name $script:ManifestPath -Force -ErrorAction 'Stop'
}

Describe 'Bsn.Common manifest' {
    It 'passes manifest validation' {
        Test-ModuleManifest -Path $script:ManifestPath | Should -Not -BeNullOrEmpty
    }

    It 'exports exactly the intended public functions' {
        $manifest = Test-ModuleManifest -Path $script:ManifestPath
        ($manifest.ExportedFunctions.Keys | Sort-Object) -join ',' | Should -Be 'Get-BsnOperatingSystem'
    }
}

Describe 'Get-BsnOperatingSystem' {
    It 'returns a BsnOperatingSystem enum value' {
        $result = Get-BsnOperatingSystem
        $result.GetType().IsEnum | Should -BeTrue
        @('Windows', 'Linux', 'macOS', 'Unknown') | Should -Contain ([string]$result)
    }

    It 'agrees with the native platform detection API' {
        $result = Get-BsnOperatingSystem
        if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
            [string]$result | Should -Be 'Windows'
        }
        elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
            [string]$result | Should -Be 'macOS'
        }
        else {
            [string]$result | Should -Be 'Linux'
        }
    }
}
