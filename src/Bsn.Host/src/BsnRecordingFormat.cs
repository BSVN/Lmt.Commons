namespace Bsn.Host
{
    /// <summary>
    /// The deliverable format of an interactive transcript recording
    /// (the RecordingOutputFormat of PowerShell-RFC#421).
    /// </summary>
    public enum BsnRecordingFormat
    {
        /// <summary>Write only the asciicast v2/v3 .cast file (default).</summary>
        Asciicast,

        /// <summary>Render an animated GIF via the external 'agg' renderer.</summary>
        Gif,

        /// <summary>Render via 'agg' and transcode to WebM via 'ffmpeg'.</summary>
        WebM,

        /// <summary>Render via 'agg' and transcode to MP4 via 'ffmpeg'.</summary>
        Mp4
    }
}
