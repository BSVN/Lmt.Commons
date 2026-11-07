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

Describe 'Import-BsnInteropAssembly (private interop loader)' {
    # https://github.com/BSVN/Lmt.Commons/issues/15
    # The loader is private: every test drives it through the defining
    # module's own scope, which is exactly how the consumer module loaders
    # invoke it.
    BeforeAll {
        $script:CommonModule = Get-Module -Name 'Bsn.Common'
        # build.ps1 compiles the sibling interop projects before any task
        # runs, so the real Bsn.Host DLL is available for load-path tests.
        $script:HostModuleRoot = Join-Path -Path (Split-Path -Parent -Path $moduleRoot) -ChildPath 'Bsn.Host'
        $script:HostDllPath = Join-Path -Path (Join-Path -Path $script:HostModuleRoot -ChildPath 'lib') -ChildPath 'Bsn.Host.dll'
    }

    It 'throws with actionable guidance when the interop assembly is missing' {
        {
            & $script:CommonModule { param($root) Import-BsnInteropAssembly -ModuleRoot $root -AssemblyName 'Bsn.Missing' } $TestDrive
        } | Should -Throw '*is missing at*Bsn.Missing.dll*to build it, or reinstall the module*'
    }

    It 'loads a fresh interop assembly through Add-Type' {
        if (-not (Test-Path -LiteralPath $script:HostDllPath)) {
            Set-ItResult -Skipped -Because 'requires the built Bsn.Host interop DLL (run ./build.ps1 first).'
        }

        # Simulate an empty session (nothing loaded yet) so the fresh-load
        # path is exercised deterministically even when an earlier task in
        # this process already imported Bsn.Host; the actual load is mocked
        # to keep the test process clean.
        Mock -ModuleName 'Bsn.Common' Get-BsnLoadedInteropAssembly { @() }
        Mock -ModuleName 'Bsn.Common' Add-Type { }

        & $script:CommonModule { param($root) Import-BsnInteropAssembly -ModuleRoot $root -AssemblyName 'Bsn.Host' } $script:HostModuleRoot

        Should -Invoke -CommandName 'Get-BsnLoadedInteropAssembly' -ModuleName 'Bsn.Common' -Times 1 -Exactly -Scope It -ParameterFilter { $AssemblyName -eq 'Bsn.Host' }
        Should -Invoke -CommandName 'Add-Type' -ModuleName 'Bsn.Common' -Times 1 -Exactly -Scope It -ParameterFilter { $Path -like '*Bsn.Host.dll' }
    }

    It 'reuses an already-loaded same-version assembly silently' {
        if (-not (Test-Path -LiteralPath $script:HostDllPath)) {
            Set-ItResult -Skipped -Because 'requires the built Bsn.Host interop DLL (run ./build.ps1 first).'
        }

        # First call loads (or reuses) the real assembly; the second call
        # takes the same-version reuse path (Import-Module -Force scenario)
        # and must succeed without any error.
        & $script:CommonModule { param($root) Import-BsnInteropAssembly -ModuleRoot $root -AssemblyName 'Bsn.Host' } $script:HostModuleRoot
        {
            & $script:CommonModule { param($root) Import-BsnInteropAssembly -ModuleRoot $root -AssemblyName 'Bsn.Host' } $script:HostModuleRoot
        } | Should -Not -Throw
    }

    It 'fails with actionable guidance when a different version is already loaded' {
        if (-not (Test-Path -LiteralPath $script:HostDllPath)) {
            Set-ItResult -Skipped -Because 'requires the built Bsn.Host interop DLL (run ./build.ps1 first).'
        }

        # The Update-Module scenario: a DIFFERENT version of the assembly is
        # already in the session. The static AppDomain cannot be faked
        # directly, so the lookup seam is mocked with a fake assembly object
        # whose version differs from the DLL on disk.
        Mock -ModuleName 'Bsn.Common' Get-BsnLoadedInteropAssembly {
            $loadedFake = [PSCustomObject]@{ Location = 'C:\Program Files\PowerShell\Modules\Bsn.Host\0.0.1\lib\Bsn.Host.dll' }
            Add-Member -InputObject $loadedFake -MemberType 'ScriptMethod' -Name 'GetName' -Value { [PSCustomObject]@{ Version = [version]'1.0.0.0' } }
            @($loadedFake)
        }

        {
            & $script:CommonModule { param($root) Import-BsnInteropAssembly -ModuleRoot $root -AssemblyName 'Bsn.Host' } $script:HostModuleRoot
        } | Should -Throw '*Cannot load Bsn.Host version*version 1.0.0.0 is already loaded in this session*restart the session*issues/15'
    }
}
