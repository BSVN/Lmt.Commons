BeforeAll {
    $moduleRoot = Split-Path -Parent -Path $PSScriptRoot
    $script:ManifestPath = Join-Path -Path $moduleRoot -ChildPath '<%= $PLASTER_PARAM_ModuleName %>.psd1'
    Import-Module -Name $script:ManifestPath -Force -ErrorAction 'Stop'
}

Describe '<%= $PLASTER_PARAM_ModuleName %> manifest' {
    It 'passes manifest validation' {
        Test-ModuleManifest -Path $script:ManifestPath | Should -Not -BeNullOrEmpty
    }

    It 'exports exactly the intended public functions' {
        $manifest = Test-ModuleManifest -Path $script:ManifestPath
        ($manifest.ExportedFunctions.Keys | Sort-Object) -join ',' | Should -Be '<%= $PLASTER_PARAM_CmdletName %>'
    }
}

Describe '<%= $PLASTER_PARAM_ModuleName %> module' {
    It 'loads and exposes its public commands' {
        Get-Command -Name '<%= $PLASTER_PARAM_CmdletName %>' -Module '<%= $PLASTER_PARAM_ModuleName %>' -ErrorAction 'SilentlyContinue' | Should -Not -BeNullOrEmpty
    }
}
