BeforeAll {
    $moduleRoot = Split-Path -Parent -Path $PSScriptRoot
    $manifestPath = Join-Path -Path $moduleRoot -ChildPath '<%= $PLASTER_PARAM_ModuleName %>.psd1'
    Import-Module -Name $manifestPath -Force -ErrorAction 'Stop'
}

Describe '<%= $PLASTER_PARAM_CmdletName %>' {
    It 'exports the command from the module' {
        Get-Command -Name '<%= $PLASTER_PARAM_CmdletName %>' -Module '<%= $PLASTER_PARAM_ModuleName %>' -ErrorAction 'SilentlyContinue' | Should -Not -BeNullOrEmpty
    }

    It 'accepts pipeline input' {
        # TODO: Replace with a meaningful assertion once the command is implemented.
        'anything' | <%= $PLASTER_PARAM_CmdletName %> -ErrorAction 'SilentlyContinue'
    }
}
