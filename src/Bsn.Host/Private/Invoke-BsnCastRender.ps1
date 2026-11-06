<#
.SYNOPSIS
    Renders a cast file to a video format (GIF, WebM or MP4).

.DESCRIPTION
    Implements the -RecordingFormat semantics of RFC 421 (Terminal Session
    Recording) at module scope: the .cast file is always the source of
    truth, video files are render products of it. Rendering uses external
    tools when they are discoverable on PATH:

    - Gif:  rendered directly by 'agg'.
    - WebM/Mp4: rendered to a temporary GIF by 'agg', then transcoded by
      'ffmpeg' (-pix_fmt yuv420p).

    When a required tool is missing, the cmdlet warns and returns $null -
    exactly the RFC's degradation contract: the .cast file remains complete
    and valid, and can be re-rendered later with different tools.
#>
function Invoke-BsnCastRender {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Rendering a file is not a state-changing operation on system state.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CastPath,

        [Parameter(Mandatory = $true)]
        [BsnRecordingFormat]$Format
    )

    $extension = $Format.ToString().ToLowerInvariant()
    $videoPath = [System.IO.Path]::ChangeExtension($CastPath, $extension)

    $aggCommand = Get-Command -Name 'agg' -ErrorAction 'SilentlyContinue'
    if (-not $aggCommand) {
        Write-Warning -Message ("Rendering to {0} requires the 'agg' renderer on PATH; the cast file '{1}' is kept as the authoritative recording." -f $Format, $CastPath)
        return $null
    }

    if ($Format -eq [BsnRecordingFormat]::Gif) {
        & $aggCommand.Source $CastPath $videoPath
        if (([int]$LASTEXITCODE -ne 0) -or (-not (Test-Path -LiteralPath $videoPath))) {
            Write-Warning -Message ("agg failed to render '{0}'; the cast file remains the authoritative recording." -f $CastPath)
            return $null
        }
        return $videoPath
    }

    $ffmpegCommand = Get-Command -Name 'ffmpeg' -ErrorAction 'SilentlyContinue'
    if (-not $ffmpegCommand) {
        Write-Warning -Message ("Rendering to {0} requires 'agg' and 'ffmpeg' on PATH; the cast file '{1}' is kept as the authoritative recording." -f $Format, $CastPath)
        return $null
    }

    $temporaryGifPath = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), 'gif')
    try {
        & $aggCommand.Source $CastPath $temporaryGifPath
        if (([int]$LASTEXITCODE -ne 0) -or (-not (Test-Path -LiteralPath $temporaryGifPath))) {
            Write-Warning -Message ("agg failed to render '{0}'; the cast file remains the authoritative recording." -f $CastPath)
            return $null
        }

        & $ffmpegCommand.Source -y -i $temporaryGifPath -pix_fmt 'yuv420p' $videoPath
        if (([int]$LASTEXITCODE -ne 0) -or (-not (Test-Path -LiteralPath $videoPath))) {
            Write-Warning -Message ("ffmpeg failed to transcode '{0}'; the cast file remains the authoritative recording." -f $CastPath)
            return $null
        }

        return $videoPath
    }
    finally {
        if (Test-Path -LiteralPath $temporaryGifPath) {
            Remove-Item -LiteralPath $temporaryGifPath -Force -ErrorAction 'SilentlyContinue'
        }
    }
}
