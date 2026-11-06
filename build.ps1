<#
.SYNOPSIS
    Build, test, package and publish entry point for the Bsn.* module fleet.

.DESCRIPTION
    Discovers every module under src/ that ships a matching <FolderName>.psd1
    manifest and runs the requested task for each one. New modules are not
    created here - they are scaffolded with Plaster via tools/New-BsnModule.ps1.

.EXAMPLE
    ./build.ps1 -Bootstrap
    Installs the development dependencies (Pester, PSScriptAnalyzer, Plaster).

.EXAMPLE
    ./build.ps1
    Runs static analysis and Pester tests for every module.

.EXAMPLE
    ./build.ps1 -Task Analyze, Test -ModulesFilter 'Bsn.SystemManagement'
    Targets a single module.

.EXAMPLE
    ./build.ps1 -Task Publish -ApiKey '<nuget-api-key>'
    Publishes every module whose version is newer than the gallery version.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [ValidateSet('Clean', 'Analyze', 'Test', 'Package', 'Publish', 'Mirror')]
    [string[]]$Task = @('Analyze', 'Test'),

    [switch]$Bootstrap,

    [string]$ModulesFilter = '*',

    [switch]$CodeCoverage,

    [string]$ApiKey,

    [string]$Repository = 'PSGallery',

    [string]$MirrorRepository,

    [string]$MirrorApiKey
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$script:OutputDirectory = Join-Path -Path $repoRoot -ChildPath 'out'
$script:Failed = $false

if ($Bootstrap.IsPresent) {
    # Make older Windows PowerShell negotiate a modern TLS version with the gallery.
    [System.Net.ServicePointManager]::SecurityProtocol = (
        [System.Net.ServicePointManager]::SecurityProtocol -bor
        [System.Net.SecurityProtocolType]::Tls12
    )

    $neededModules = @(
        @{ Name = 'Pester'; MinimumVersion = '5.7.1'; SkipPublisherCheck = $true },
        @{ Name = 'PSScriptAnalyzer'; MinimumVersion = '1.22.0' },
        @{ Name = 'Plaster'; MinimumVersion = '1.1.3' }
    )

    foreach ($neededModule in $neededModules) {
        $available = Get-Module -Name $neededModule.Name -ListAvailable |
            Where-Object -FilterScript { $_.Version -ge [version]$neededModule.MinimumVersion }
        if ($available) { continue }

        Write-Host ("Installing {0} {1}+..." -f $neededModule.Name, $neededModule.MinimumVersion)
        $installParameters = @{
            Name           = $neededModule.Name
            MinimumVersion = $neededModule.MinimumVersion
            Scope          = 'CurrentUser'
            Force          = $true
        }
        if ($neededModule.SkipPublisherCheck) {
            $installParameters['SkipPublisherCheck'] = $true
        }
        Install-Module @installParameters
    }
}

foreach ($requiredModule in @('Pester', 'PSScriptAnalyzer')) {
    if (-not (Get-Module -Name $requiredModule -ListAvailable)) {
        throw ("{0} is not available. Run './build.ps1 -Bootstrap' first." -f $requiredModule)
    }
}

function Invoke-ModuleCompile {
    [CmdletBinding()]
    param()

    $projects = Get-ChildItem -Path (Join-Path -Path $repoRoot -ChildPath 'src') -Filter '*.csproj' -Recurse -File -ErrorAction 'SilentlyContinue'
    if ($projects.Count -eq 0) { return }

    $dotnetCommand = Get-Command -Name 'dotnet' -ErrorAction 'SilentlyContinue'
    if (-not $dotnetCommand) {
        # Already-built outputs keep Analyze/Test usable without the SDK.
        $missingOutputs = @($projects | Where-Object -FilterScript {
                -not (Test-Path -LiteralPath (Join-Path -Path $_.DirectoryName -ChildPath 'lib'))
            })
        if ($missingOutputs.Count -gt 0) {
            throw ("C# projects found but the .NET SDK was not found on PATH and no built output exists for: {0}. Install the .NET SDK (https://dotnet.microsoft.com/download) or run './build.ps1 -Bootstrap'." -f (($missingOutputs | ForEach-Object -Process { $_.FullName }) -join ', '))
        }
        return
    }

    foreach ($project in $projects) {
        Write-Host ("==> Compiling {0}" -f $project.BaseName)
        & $dotnetCommand.Source build $project.FullName --configuration 'Release' --nologo --verbosity 'quiet'
        if ($LASTEXITCODE -ne 0) {
            throw ("dotnet build failed for '{0}'." -f $project.FullName)
        }
    }
}

# Compile every module's C# interop project before any task runs.
Invoke-ModuleCompile

function Get-BuildModule {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Filter = $ModulesFilter
    )

    $discoveredModules = @(
        foreach ($moduleDirectory in (Get-ChildItem -Path (Join-Path -Path $repoRoot -ChildPath 'src') -Directory -ErrorAction 'SilentlyContinue')) {
            $manifestPath = Join-Path -Path $moduleDirectory.FullName -ChildPath ($moduleDirectory.Name + '.psd1')
            if (Test-Path -LiteralPath $manifestPath) {
                [pscustomobject]@{
                    Name         = $moduleDirectory.Name
                    Path         = $moduleDirectory.FullName
                    ManifestPath = $manifestPath
                }
            }
        }
    )

    $selectedModules = @($discoveredModules | Where-Object -FilterScript { $_.Name -like $Filter })

    if ($selectedModules.Count -eq 0) {
        throw ("No modules under src/ match the ModulesFilter '{0}'." -f $Filter)
    }

    return $selectedModules
}

function Invoke-BuildTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    Write-Host ''
    Write-Host ('==== {0} ====' -f $Name) -ForegroundColor Cyan
    try {
        & $Action
    }
    catch {
        $script:Failed = $true
        Write-Error -ErrorRecord $_
    }
}

$taskMap = @{
    Clean = {
        if (Test-Path -LiteralPath $script:OutputDirectory) {
            Remove-Item -LiteralPath $script:OutputDirectory -Recurse -Force
        }
        Write-Host ("Cleaned '{0}'." -f $script:OutputDirectory)
    }

    Analyze = {
        Import-Module -Name PSScriptAnalyzer -ErrorAction 'Stop'
        foreach ($module in (Get-BuildModule)) {
            Write-Host ("==> Analyzing {0}" -f $module.Name)
            $findings = @(Invoke-ScriptAnalyzer -Path $module.Path -Recurse -Severity 'Error', 'Warning' -ErrorAction 'Stop')
            if ($findings.Count -gt 0) {
                $findings | Format-Table -AutoSize | Out-String -Width 200 | Write-Host -ForegroundColor Yellow
                throw ('{0} failed PSScriptAnalyzer with {1} finding(s).' -f $module.Name, $findings.Count)
            }
            Write-Host ("==> {0}: no analyzer findings." -f $module.Name)
        }
    }

    Test = {
        foreach ($module in (Get-BuildModule)) {
            $moduleTestDirectory = Join-Path -Path $module.Path -ChildPath 'tests'
            if (-not (Test-Path -LiteralPath $moduleTestDirectory)) {
                Write-Warning -Message ("No tests found for {0} (expected '{1}')." -f $module.Name, $moduleTestDirectory)
                continue
            }

            $null = New-Item -ItemType 'Directory' -Path $script:OutputDirectory -Force
            $testResultPath = Join-Path -Path $script:OutputDirectory -ChildPath ('testResults.{0}.xml' -f $module.Name)

            $pesterConfiguration = New-PesterConfiguration
            $pesterConfiguration.Run.Path = $moduleTestDirectory
            $pesterConfiguration.Run.PassThru = $true
            $pesterConfiguration.Run.Exit = $false
            $pesterConfiguration.TestResult.Enabled = $true
            $pesterConfiguration.TestResult.OutputPath = $testResultPath
            $pesterConfiguration.TestResult.OutputFormat = 'NUnitXml'
            $pesterConfiguration.Output.Verbosity = 'Detailed'

            if ($CodeCoverage.IsPresent) {
                # JaCoCo XML per module; Codecov merges the reports (flagged by module).
                $coveragePath = Join-Path -Path $script:OutputDirectory -ChildPath ('coverage.{0}.xml' -f $module.Name)
                $pesterConfiguration.CodeCoverage.Enabled = $true
                $pesterConfiguration.CodeCoverage.Path = @(
                    Get-ChildItem -LiteralPath $module.Path -Recurse -Include '*.ps1', '*.psm1' -File |
                        Where-Object -FilterScript { $_.FullName -notmatch '\\tests\\' } |
                        ForEach-Object -Process { $_.FullName }
                )
                $pesterConfiguration.CodeCoverage.OutputPath = $coveragePath
                $pesterConfiguration.CodeCoverage.OutputFormat = 'JaCoCo'
            }

            Write-Host ("==> Testing {0}" -f $module.Name)
            # Make repo sibling modules (e.g. Bsn.Common) resolvable for RequiredModules validation.
            $sourceDirectory = Join-Path -Path $repoRoot -ChildPath 'src'
            $previousModulePath = $env:PSModulePath
            $env:PSModulePath = '{0}{1}{2}' -f $sourceDirectory, [System.IO.Path]::PathSeparator, $env:PSModulePath
            # Pester needs Continue: the surrounding Stop mode turns every Write-Warning
            # inside test execution into a container-level failure.
            $previousErrorActionPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $result = Invoke-Pester -Configuration $pesterConfiguration
            }
            finally {
                $ErrorActionPreference = $previousErrorActionPreference
                $env:PSModulePath = $previousModulePath
            }
            if ($result.FailedCount -gt 0) {
                throw ('{0}: {1} of {2} test(s) failed.' -f $module.Name, $result.FailedCount, $result.TotalCount)
            }
            Write-Host ("==> {0}: {1} test(s) passed." -f $module.Name, $result.PassedCount)
        }
    }

    Package = {
        # Staged manifests validate their RequiredModules (e.g. Bsn.Common) - make
        # repo siblings resolvable, like the Test task does.
        $sourceDirectory = Join-Path -Path $repoRoot -ChildPath 'src'
        $previousModulePath = $env:PSModulePath
        $env:PSModulePath = '{0}{1}{2}' -f $sourceDirectory, [System.IO.Path]::PathSeparator, $env:PSModulePath
        try {
            foreach ($module in (Get-BuildModule)) {
                $moduleOutputDirectory = Join-Path -Path $script:OutputDirectory -ChildPath 'modules'
                $null = New-Item -ItemType 'Directory' -Path $moduleOutputDirectory -Force
                $stagedModulePath = Join-Path -Path $moduleOutputDirectory -ChildPath $module.Name
                $null = New-Item -ItemType 'Directory' -Path $stagedModulePath -Force

                Copy-Item -Path (Join-Path -Path $module.Path -ChildPath '*') -Destination $stagedModulePath -Recurse -Force
                Remove-Item -LiteralPath (Join-Path -Path $stagedModulePath -ChildPath 'tests') -Recurse -Force -ErrorAction 'SilentlyContinue'
                Remove-Item -LiteralPath (Join-Path -Path $stagedModulePath -ChildPath 'src') -Recurse -Force -ErrorAction 'SilentlyContinue'
                Remove-Item -LiteralPath (Join-Path -Path $stagedModulePath -ChildPath 'obj') -Recurse -Force -ErrorAction 'SilentlyContinue'
                Get-ChildItem -LiteralPath $stagedModulePath -Filter '*.csproj' -File -ErrorAction 'SilentlyContinue' | Remove-Item -Force -ErrorAction 'SilentlyContinue'

                $manifest = Test-ModuleManifest -Path (Join-Path -Path $stagedModulePath -ChildPath ($module.Name + '.psd1')) -ErrorAction 'Stop'

                $packageOutputDirectory = Join-Path -Path $script:OutputDirectory -ChildPath 'packages'
                $null = New-Item -ItemType 'Directory' -Path $packageOutputDirectory -Force
                $packagePath = Join-Path -Path $packageOutputDirectory -ChildPath ('{0}.{1}.zip' -f $module.Name, $manifest.Version)
                Compress-Archive -Path (Join-Path -Path $stagedModulePath -ChildPath '*') -DestinationPath $packagePath -Force

                Write-Host ("==> {0}: packaged version {1} to {2}" -f $module.Name, $manifest.Version, $packagePath)
            }
        }
        finally {
            $env:PSModulePath = $previousModulePath
        }
    }

    Publish = {
        $resolvedApiKey = if ($ApiKey) { $ApiKey } else { $env:PS_GALLERY_KEY }
        if (-not $resolvedApiKey) {
            throw 'No PowerShell Gallery API key was provided. Use -ApiKey or set $env:PS_GALLERY_KEY.'
        }

        # Staged manifests validate their RequiredModules (e.g. Bsn.Common) - make
        # repo siblings resolvable, like the Test task does.
        $sourceDirectory = Join-Path -Path $repoRoot -ChildPath 'src'
        $previousModulePath = $env:PSModulePath
        $env:PSModulePath = '{0}{1}{2}' -f $sourceDirectory, [System.IO.Path]::PathSeparator, $env:PSModulePath
        try {
            foreach ($module in (Get-BuildModule)) {
                $moduleOutputDirectory = Join-Path -Path $script:OutputDirectory -ChildPath 'modules'
                $stagedModulePath = Join-Path -Path $moduleOutputDirectory -ChildPath $module.Name
                if (-not (Test-Path -LiteralPath $stagedModulePath)) {
                    throw ("'{0}' has not been packaged yet. Run the Package task first." -f $stagedModulePath)
                }

                $manifest = Test-ModuleManifest -Path (Join-Path -Path $stagedModulePath -ChildPath ($module.Name + '.psd1')) -ErrorAction 'Stop'

                Write-Host ("==> Checking gallery state for {0}" -f $module.Name)
                $publishedModule = Find-Module -Name $module.Name -Repository $Repository -ErrorAction 'SilentlyContinue'
                if ($publishedModule -and ($publishedModule.Version -ge $manifest.Version)) {
                    Write-Host ("==> {0}: gallery already has version {1}; skipping publish (local: {2})." -f $module.Name, $publishedModule.Version, $manifest.Version)
                    continue
                }

                Write-Host ("==> Publishing {0} version {1} to {2}" -f $module.Name, $manifest.Version, $Repository)
                Publish-Module -Path $stagedModulePath -NuGetApiKey $resolvedApiKey -Repository $Repository -ErrorAction 'Stop'
                Write-Host ("==> {0}: published." -f $module.Name)
            }
        }
        finally {
            $env:PSModulePath = $previousModulePath
        }
    }

    Mirror = {
        # Publishes the staged modules to a second NuGet feed (GitHub Packages
        # mirror) in two steps:
        #   1. produce .nupkg files by publishing into a LOCAL file-share repository
        #      (PowerShellGet cannot push to authenticated NuGet v3 feeds directly:
        #      its provider fetches the service index unauthenticated and gets 401)
        #   2. dotnet nuget push each .nupkg using a generated nuget.config that
        #      carries the feed credentials; --skip-duplicate makes re-runs
        #      idempotent (a version that already exists is skipped)
        if (-not $MirrorRepository) {
            throw 'No mirror repository was provided. Use -MirrorRepository <nuget-feed-url> (e.g. https://nuget.pkg.github.com/<org>/index.json).'
        }

        $resolvedMirrorKey = if ($MirrorApiKey) { $MirrorApiKey } else { $env:GITHUB_TOKEN }
        if (-not $resolvedMirrorKey) {
            throw 'No mirror API key was provided. Use -MirrorApiKey or set $env:GITHUB_TOKEN.'
        }

        # GitHub Packages authenticates with the feed owner (from the URL) + token.
        $feedOwner = if ($MirrorRepository -match 'nuget\.pkg\.github\.com/([^/]+)/') { $Matches[1] } else { 'token' }

        $nupkgDirectory = Join-Path -Path $script:OutputDirectory -ChildPath 'nupkg'
        $null = New-Item -ItemType 'Directory' -Path $nupkgDirectory -Force

        Register-PSRepository -Name 'BsnLocalNupkg' -SourceLocation $nupkgDirectory -PublishLocation $nupkgDirectory -InstallationPolicy 'Trusted' -ErrorAction 'Stop'

        # Publish-Module validates the staged manifest including RequiredModules -
        # make repo siblings resolvable, like the Test/Package tasks do.
        $sourceDirectory = Join-Path -Path $repoRoot -ChildPath 'src'
        $previousModulePath = $env:PSModulePath
        $env:PSModulePath = '{0}{1}{2}' -f $sourceDirectory, [System.IO.Path]::PathSeparator, $env:PSModulePath
        try {
            foreach ($module in (Get-BuildModule)) {
                $moduleOutputDirectory = Join-Path -Path $script:OutputDirectory -ChildPath 'modules'
                $stagedModulePath = Join-Path -Path $moduleOutputDirectory -ChildPath $module.Name
                if (-not (Test-Path -LiteralPath $stagedModulePath)) {
                    throw ("'{0}' has not been packaged yet. Run the Package task first." -f $stagedModulePath)
                }

                $stagedManifest = Test-ModuleManifest -Path (Join-Path -Path $stagedModulePath -ChildPath ($module.Name + '.psd1')) -ErrorAction 'Stop'

                # Local publish: refresh this module's .nupkg (idempotent overwrite).
                Get-ChildItem -LiteralPath $nupkgDirectory -Filter ($module.Name + '*.nupkg') -File -ErrorAction 'SilentlyContinue' |
                    Remove-Item -Force -ErrorAction 'SilentlyContinue'

                Write-Host ("==> Packing {0} {1}" -f $module.Name, $stagedManifest.Version)
                Publish-Module -Path $stagedModulePath -Repository 'BsnLocalNupkg' -ErrorAction 'Stop'
            }
        }
        finally {
            $env:PSModulePath = $previousModulePath
            Unregister-PSRepository -Name 'BsnLocalNupkg' -ErrorAction 'SilentlyContinue'
        }

        # Push each .nupkg with a credentials-carrying nuget.config.
        $nugetConfigPath = Join-Path -Path $script:OutputDirectory -ChildPath 'nuget.config'
        $escapedFeed = $MirrorRepository -replace '&', '&amp;'
        $configContent = @(
            '<?xml version="1.0" encoding="utf-8"?>'
            '<configuration>'
            '  <packageSources>'
            '    <add key="BsnMirror" value="' + $escapedFeed + '" />'
            '  </packageSources>'
            '  <packageSourceCredentials>'
            '    <BsnMirror>'
            '      <add key="Username" value="' + $feedOwner + '" />'
            '      <add key="ClearTextPassword" value="' + $resolvedMirrorKey + '" />'
            '    </BsnMirror>'
            '  </packageSourceCredentials>'
            '</configuration>'
        )
        $configContent | Set-Content -LiteralPath $nugetConfigPath -Encoding UTF8

        $dotnetCommand = Get-Command -Name 'dotnet' -ErrorAction 'Stop'
        foreach ($nupkgFile in (Get-ChildItem -LiteralPath $nupkgDirectory -Filter '*.nupkg' -File)) {
            Write-Host ("==> Mirroring {0} to {1}" -f $nupkgFile.Name, $MirrorRepository)
            $null = & $dotnetCommand.Source nuget push $nupkgFile.FullName --source 'BsnMirror' --configfile $nugetConfigPath --skip-duplicate
            if ($LASTEXITCODE -ne 0) {
                throw ("dotnet nuget push failed for '{0}' (exit code {1})." -f $nupkgFile.Name, $LASTEXITCODE)
            }
            Write-Host ("==> {0}: mirrored." -f $nupkgFile.Name)
        }

        # The generated config carries the token in clear text - remove it.
        Remove-Item -LiteralPath $nugetConfigPath -Force -ErrorAction 'SilentlyContinue'
    }
}

foreach ($taskName in $Task) {
    Invoke-BuildTask -Name $taskName -Action $taskMap[$taskName]
}

if ($script:Failed) {
    exit 1
}
