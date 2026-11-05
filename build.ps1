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
    [ValidateSet('Clean', 'Analyze', 'Test', 'Package', 'Publish')]
    [string[]]$Task = @('Analyze', 'Test'),

    [switch]$Bootstrap,

    [string]$ModulesFilter = '*',

    [string]$ApiKey,

    [string]$Repository = 'PSGallery'
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

            Write-Host ("==> Testing {0}" -f $module.Name)
            $result = Invoke-Pester -Configuration $pesterConfiguration
            if ($result.FailedCount -gt 0) {
                throw ('{0}: {1} of {2} test(s) failed.' -f $module.Name, $result.FailedCount, $result.TotalCount)
            }
            Write-Host ("==> {0}: {1} test(s) passed." -f $module.Name, $result.PassedCount)
        }
    }

    Package = {
        foreach ($module in (Get-BuildModule)) {
            $moduleOutputDirectory = Join-Path -Path $script:OutputDirectory -ChildPath 'modules'
            $null = New-Item -ItemType 'Directory' -Path $moduleOutputDirectory -Force
            $stagedModulePath = Join-Path -Path $moduleOutputDirectory -ChildPath $module.Name
            $null = New-Item -ItemType 'Directory' -Path $stagedModulePath -Force

            Copy-Item -Path (Join-Path -Path $module.Path -ChildPath '*') -Destination $stagedModulePath -Recurse -Force
            Remove-Item -LiteralPath (Join-Path -Path $stagedModulePath -ChildPath 'tests') -Recurse -Force -ErrorAction 'SilentlyContinue'

            $manifest = Test-ModuleManifest -Path (Join-Path -Path $stagedModulePath -ChildPath ($module.Name + '.psd1')) -ErrorAction 'Stop'

            $packageOutputDirectory = Join-Path -Path $script:OutputDirectory -ChildPath 'packages'
            $null = New-Item -ItemType 'Directory' -Path $packageOutputDirectory -Force
            $packagePath = Join-Path -Path $packageOutputDirectory -ChildPath ('{0}.{1}.zip' -f $module.Name, $manifest.Version)
            Compress-Archive -Path (Join-Path -Path $stagedModulePath -ChildPath '*') -DestinationPath $packagePath -Force

            Write-Host ("==> {0}: packaged version {1} to {2}" -f $module.Name, $manifest.Version, $packagePath)
        }
    }

    Publish = {
        $resolvedApiKey = if ($ApiKey) { $ApiKey } else { $env:PS_GALLERY_KEY }
        if (-not $resolvedApiKey) {
            throw 'No PowerShell Gallery API key was provided. Use -ApiKey or set $env:PS_GALLERY_KEY.'
        }

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
}

foreach ($taskName in $Task) {
    Invoke-BuildTask -Name $taskName -Action $taskMap[$taskName]
}

if ($script:Failed) {
    exit 1
}
