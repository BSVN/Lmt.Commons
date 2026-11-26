using System;
using System.Globalization;
using System.Text;

namespace Bsn.Host.Interop
{
    /// <summary>
    /// Capture-time audit metadata: the session context a recording stamps
    /// into its cast header's "bsn" block - who ran the session, where, and
    /// which module and PowerShell recorded it. The asciicast format treats
    /// unknown header keys as ignorable, so the block leaves the cast
    /// playable by any asciicast implementation.
    ///
    /// It is a .NET type so that it crosses the PowerShell/C# boundary
    /// typed: Start-InteractiveTranscript (PowerShell) fills it in once,
    /// the engine wrappers pass it on, and both cast writers serialize it
    /// with ToHeaderJson() - the ConPTY CastWriter in this assembly on
    /// Windows, and ConvertTo-BsnAsciicast (PowerShell) for the script(1)
    /// engine on Unix. That makes this class the single definition of the
    /// block's shape for both engines. Downstream readers
    /// (ConvertTo-BsnTranscript, the audit export) parse the block from the
    /// cast header; its key names are part of the recording format.
    /// </summary>
    public sealed class AuditMetadata
    {
        /// <summary>
        /// GUID minted when the recording starts. Block key "session_id".
        /// </summary>
        public string SessionId { get; set; }

        /// <summary>
        /// Module that made the recording, for example 'bsn.host 0.3.0'.
        /// Block key "recorded_by".
        /// </summary>
        public string RecordedBy { get; set; }

        /// <summary>
        /// Machine the recorded session ran on. Block key "host".
        /// </summary>
        public string ComputerName { get; set; }

        /// <summary>
        /// Account that started the recording. Block key "user".
        /// </summary>
        public string UserName { get; set; }

        /// <summary>
        /// Process id of the PowerShell that made the recording. Block key
        /// "pid", written as a JSON number. Zero (the default) leaves the
        /// key out of the block.
        /// </summary>
        public int ProcessId { get; set; }

        /// <summary>
        /// Version of the PowerShell that made the recording, for example
        /// '7.6.9'. Block key "psversion".
        /// </summary>
        public string PSVersion { get; set; }

        /// <summary>
        /// Edition of the PowerShell that made the recording: 'Core' or
        /// 'Desktop'. Block key "psedition".
        /// </summary>
        public string Edition { get; set; }

        /// <summary>
        /// The "bsn" block as a compact JSON object, ready to be spliced
        /// into the cast header, for example
        /// {"session_id":"...","recorded_by":"...","host":"..."}.
        ///
        /// Keys follow the fixed order of the properties above. A property
        /// that is null or empty is left out, so a block never carries empty
        /// values. The result is an empty string when nothing is set, which
        /// tells the writers to leave the block out of the header entirely.
        /// Values are escaped by the same routine the rest of the header
        /// uses (JsonText), so the header stays one line of valid JSON
        /// whatever the values contain.
        /// </summary>
        public string ToHeaderJson()
        {
            StringBuilder block = new StringBuilder();
            AppendField(block, "session_id", SessionId);
            AppendField(block, "recorded_by", RecordedBy);
            AppendField(block, "host", ComputerName);
            AppendField(block, "user", UserName);
            if (ProcessId > 0)
            {
                AppendFieldSeparator(block);
                block.Append("\"pid\":").Append(ProcessId.ToString(CultureInfo.InvariantCulture));
            }
            AppendField(block, "psversion", PSVersion);
            AppendField(block, "psedition", Edition);

            if (block.Length == 0)
            {
                return string.Empty;
            }
            return "{" + block.ToString() + "}";
        }

        /// <summary>
        /// Appends one "key":"value" field to block, skipping null or
        /// empty values. key is the bare property name; both it and the
        /// value are written as quoted, escaped JSON strings.
        /// </summary>
        private static void AppendField(StringBuilder block, string key, string value)
        {
            if (string.IsNullOrEmpty(value))
            {
                return;
            }
            AppendFieldSeparator(block);
            block.Append(JsonText.Quote(key)).Append(':').Append(JsonText.Quote(value));
        }

        /// <summary>
        /// Appends the comma that separates two fields, unless block is
        /// still empty (the field being appended is the first one).
        /// </summary>
        private static void AppendFieldSeparator(StringBuilder block)
        {
            if (block.Length > 0)
            {
                block.Append(',');
            }
        }
    }
}
