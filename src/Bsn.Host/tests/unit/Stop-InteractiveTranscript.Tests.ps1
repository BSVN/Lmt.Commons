BeforeAll {
    $moduleRoot = Split-Path -Parent -Path (Split-Path -Parent -Path $PSScriptRoot)
    $manifestPath = Join-Path -Path $moduleRoot -ChildPath 'Bsn.Host.psd1'
    # The module's DLL may already be loaded in this process (e.g., by PSScriptAnalyzer
    # analyzing the manifest), which makes Import-Module fail with FileLoadException.
    # Fall back to importing the psm1 directly - the assembly is already in memory.
    try {
        Import-Module -Name $manifestPath -Force -ErrorAction 'Stop'
    }
    catch [System.IO.FileLoadException] {
        Import-Module -Name (Join-Path $moduleRoot 'Bsn.Host.psm1') -Force -ErrorAction 'Stop'
    }
}

Describe 'Stop-InteractiveTranscript' {
    Context 'without an active recording' {
        BeforeAll {
            $script:SavedStopFile = $env:BsnHostRecordingStopFile
            Remove-Item -LiteralPath Env:\BsnHostRecordingStopFile -ErrorAction 'SilentlyContinue'
        }
        AfterAll {
            if ($script:SavedStopFile) { $env:BsnHostRecordingStopFile = $script:SavedStopFile }
        }

        It 'throws an explanatory error' {
            { Stop-InteractiveTranscript -ErrorAction 'Stop' } | Should -Throw '*No interactive transcript is running*'
        }
    }

    Context 'with an active recording' {
        BeforeAll {
            $script:StopFilePath = Join-Path -Path $TestDrive -ChildPath 'active.stop'
            $env:BsnHostRecordingStopFile = $script:StopFilePath
        }
        AfterEach {
            Remove-Item -LiteralPath $script:StopFilePath -Force -ErrorAction 'SilentlyContinue'
        }
        AfterAll {
            Remove-Item -LiteralPath Env:\BsnHostRecordingStopFile -ErrorAction 'SilentlyContinue'
        }

        It 'creates the stop signal file' {
            Stop-InteractiveTranscript
            (Test-Path -LiteralPath $script:StopFilePath) | Should -BeTrue
        }

        It 'is idempotent when a stop request is already pending' {
            Set-Content -LiteralPath $script:StopFilePath -Value 'stop'
            { Stop-InteractiveTranscript -ErrorAction 'Stop' } | Should -Not -Throw
            (Get-Content -LiteralPath $script:StopFilePath -Raw).Trim() | Should -Be 'stop'
        }
    }
}
