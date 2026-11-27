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
        ($manifest.ExportedFunctions.Keys | Sort-Object) -join ',' | Should -Be 'ConvertTo-BsnTranscript,Show-InteractiveTranscript,Start-InteractiveTranscript,Stop-InteractiveTranscript'
    }

    It 'exposes the online-help HelpUri for every public function' {
        foreach ($recordedCommand in (Get-Command -Module 'Bsn.Host')) {
            $onlineUri = 'https://bsvn.github.io/Lmt.Commons/en-US/{0}.html' -f $recordedCommand.Name
            $recordedCommand.HelpUri | Should -Be $onlineUri
        }
    }

    It 'stamps the interop assembly with the manifest version (issue #15)' {
        # With the default AssemblyVersion 1.0.0.0 in every release the loader
        # could not tell versions apart: Import-Module -Force after
        # Update-Module failed with FileLoadException (issue #15).
        $dllPath = Join-Path -Path $moduleRoot -ChildPath 'lib/Bsn.Host.dll'
        Test-Path -LiteralPath $dllPath | Should -BeTrue
        [System.Reflection.AssemblyName]::GetAssemblyName($dllPath).Version.ToString(3) |
            Should -Be (Test-ModuleManifest -Path $script:ManifestPath).Version.ToString()
    }
}

Describe 'Bsn.Host module' {
    It 'loads and exposes its public commands' {
        foreach ($commandName in @('Start-InteractiveTranscript', 'Stop-InteractiveTranscript', 'Show-InteractiveTranscript', 'ConvertTo-BsnTranscript')) {
            Get-Command -Name $commandName -Module 'Bsn.Host' -ErrorAction 'SilentlyContinue' | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Bsn.Host interop dependencies' {
    # The interop assembly takes System.Text.Json from NuGet to write cast
    # files. Bsn.Host.dll is loaded with Add-Type -Path, which resolves no
    # dependencies itself, so each PowerShell edition supplies the library
    # from where it has it: PowerShell 7 from its own $PSHOME (the in-box
    # copy always wins there), Windows PowerShell 5.1, which has none, from
    # the copies shipped in lib/. The last test runs in a child process:
    # the module is already loaded in this one, and CI only ever runs pwsh.
    BeforeAll {
        # The assembly references of a DLL, read without running its code.
        function Get-BsnAssemblyReference {
            param([string]$Path)

            if ($PSVersionTable.PSEdition -eq 'Core') {
                # .NET has no reflection-only loading: read them in a throwaway load context.
                $context = [System.Runtime.Loader.AssemblyLoadContext]::new('BsnHostDependencyProbe', $true)
                try {
                    return @($context.LoadFromAssemblyPath($Path).GetReferencedAssemblies())
                }
                finally {
                    $context.Unload()
                }
            }
            return @([System.Reflection.Assembly]::ReflectionOnlyLoadFrom($Path).GetReferencedAssemblies())
        }
    }

    It 'ships every dependency at exactly the version the assemblies reference' {
        # .NET Framework binds each assembly reference to exactly the
        # referenced version, and a PowerShell session has no binding
        # redirects. So lib/ has to be self-contained: every reference has
        # to be either a shipped DLL of exactly that version, or part of
        # the .NET Framework itself. A dependency update can break this
        # without any test on PowerShell 7 noticing, because there the
        # library PowerShell ships always wins over the shipped copies. (The
        # 8.0 line of System.Text.Json, for one, references a
        # System.Runtime.CompilerServices.Unsafe older than the one it is
        # packaged with.)
        $frameworkProvided = 'netstandard', 'System.Numerics.Vectors'
        $libPath = Join-Path -Path $moduleRoot -ChildPath 'lib'
        $libraryFiles = @(Get-ChildItem -LiteralPath $libPath -Filter '*.dll' -File)
        $shippedVersions = @{}
        foreach ($libraryFile in $libraryFiles) {
            $shippedVersions[$libraryFile.BaseName] = [System.Reflection.AssemblyName]::GetAssemblyName($libraryFile.FullName).Version
        }

        foreach ($libraryFile in $libraryFiles) {
            foreach ($reference in (Get-BsnAssemblyReference -Path $libraryFile.FullName)) {
                if ($reference.Name -in $frameworkProvided) { continue }

                $shippedVersions.ContainsKey($reference.Name) | Should -BeTrue -Because ('{0} references {1} {2}, which is neither shipped in lib/ nor part of the .NET Framework.' -f $libraryFile.Name, $reference.Name, $reference.Version)
                $shippedVersions[$reference.Name] | Should -Be $reference.Version -Because ('{0} references {1} {2}, but Windows PowerShell 5.1 can only bind the exact version that is shipped.' -f $libraryFile.Name, $reference.Name, $reference.Version)
            }
        }
    }

    It 'pins System.Text.Json to the major version PowerShell 7.6 ships' {
        # The package version is the floor for the PowerShell 7 releases that
        # can record: PowerShell 7 binds the System.Text.Json it ships with,
        # and only when that is at least as new as the one this module was
        # built against. 10.0 is what PowerShell 7.6, the oldest release that
        # still gets support, ships. A newer major version would drop it
        # without any test noticing - CI runs the newest pwsh, where
        # everything binds - so moving this number is a decision that also
        # updates the requirement in about_Bsn.Host and README.md.
        [System.Reflection.AssemblyName]::GetAssemblyName((Join-Path -Path $moduleRoot -ChildPath 'lib/System.Text.Json.dll')).Version.Major | Should -Be 10
    }
    It 'writes cast JSON with the System.Text.Json of the running PowerShell edition' {
        $expectedDirectory = if ($PSVersionTable.PSEdition -eq 'Core') { $PSHOME } else { Join-Path -Path $moduleRoot -ChildPath 'lib' }

        $header = [Bsn.Host.Interop.CastJson]::Header(2, 80, 24, 1793895000, 'shell', 'title', $null)

        Split-Path -Parent -Path ([System.Text.Json.Utf8JsonWriter].Assembly.Location) | Should -Be $expectedDirectory
        ($header | ConvertFrom-Json).version | Should -Be 2
    }

    It 'loads, and writes cast JSON, in Windows PowerShell 5.1' {
        $windowsPowerShell = Get-Command -Name 'powershell.exe' -ErrorAction 'SilentlyContinue'
        if (-not $windowsPowerShell) {
            Set-ItResult -Skipped -Because 'Windows PowerShell 5.1 is only available on Windows.'
        }

        $runnerPath = Join-Path -Path $TestDrive -ChildPath 'windows-powershell-runner.ps1'
        $resultPath = Join-Path -Path $TestDrive -ChildPath 'windows-powershell-result.json'
        $stderrPath = Join-Path -Path $TestDrive -ChildPath 'windows-powershell-stderr.txt'
        @'
param([string]$SourceDirectory, [string]$ManifestPath, [string]$ResultPath)
$ErrorActionPreference = 'Stop'
try {
    # Same module path as the build's Test task: the repository's src folder
    # first, so the manifest's RequiredModules (Bsn.Common) resolves.
    $env:PSModulePath = $SourceDirectory + [System.IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module -Name $ManifestPath -Force

    $metadata = [Bsn.Host.Interop.AuditMetadata]@{ UserName = 'jdoe'; ProcessId = 4242 }
    $text = 'say "hi"' + [char]10 + [char]27 + [char]0x2500
    $result = @{
        Edition              = $PSVersionTable.PSEdition
        Version              = $PSVersionTable.PSVersion.ToString()
        Header               = [Bsn.Host.Interop.CastJson]::Header(2, 80, 24, 1793895000, 'shell', 'title', $metadata)
        Event                = [Bsn.Host.Interop.CastJson]::Event(0.5, 6, 'o', $text)
        JsonAssemblyLocation = [System.Text.Json.Utf8JsonWriter].Assembly.Location
    }
}
catch {
    $result = @{ Error = ($_ | Out-String) }
}
[System.IO.File]::WriteAllText($ResultPath, ($result | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
if ($result.ContainsKey('Error')) { exit 1 }
'@ | Set-Content -LiteralPath $runnerPath -Encoding UTF8

        $process = Start-Process -FilePath $windowsPowerShell.Source -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            ('"{0}"' -f $runnerPath),
            ('"{0}"' -f (Split-Path -Parent -Path $moduleRoot)),
            ('"{0}"' -f $script:ManifestPath),
            ('"{0}"' -f $resultPath)
        ) -WindowStyle 'Hidden' -RedirectStandardError $stderrPath -PassThru
        if (-not $process.WaitForExit(120000)) {
            $process.Kill()
            throw 'Windows PowerShell 5.1 did not finish within 120 seconds.'
        }
        if (-not (Test-Path -LiteralPath $resultPath)) {
            $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '<no stderr>' }
            throw ("Windows PowerShell 5.1 produced no result (exit code {0}). Stderr: {1}" -f $process.ExitCode, $stderr)
        }

        $outcome = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $outcome.Error | Should -BeNullOrEmpty
        $outcome.Edition | Should -Be 'Desktop'
        $outcome.Version | Should -BeLike '5.1.*'
        Split-Path -Parent -Path $outcome.JsonAssemblyLocation | Should -Be (Join-Path -Path $moduleRoot -ChildPath 'lib')
        $outcome.Header | Should -Be '{"version":2,"width":80,"height":24,"timestamp":1793895000,"title":"title","env":{"SHELL":"shell","TERM":"xterm-256color"},"bsn":{"user":"jdoe","pid":4242}}'
        $outcome.Event | Should -Be ('[0.5,"o","say \"hi\"\n\u001B' + [char]0x2500 + '"]')
    }
}

