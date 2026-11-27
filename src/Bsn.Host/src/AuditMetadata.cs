using System.Text.Json;

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
    /// the engine wrappers pass it on, and CastJson.Header writes it into
    /// the header for both engines - the ConPTY CastWriter in this assembly
    /// on Windows, and ConvertTo-BsnAsciicast (PowerShell) for the script(1)
    /// engine on Unix. That makes this class the single definition of the
    /// block's shape. Downstream readers (ConvertTo-BsnTranscript, the audit
    /// export) parse the block from the cast header; its key names are part
    /// of the recording format.
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
        /// "pid", written as a JSON number. Zero (the default) or a negative
        /// value leaves the key out of the block.
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
        /// True when no field carries a value. The cast writers leave the
        /// "bsn" block out of the header for such an object (see IsEmpty and
        /// WriteTo: both decide per field what counts as a value, so they
        /// have to agree).
        /// </summary>
        internal bool IsEmpty
        {
            get
            {
                return IsUnset(SessionId)
                    && IsUnset(RecordedBy)
                    && IsUnset(ComputerName)
                    && IsUnset(UserName)
                    && (ProcessId <= 0)
                    && IsUnset(PSVersion)
                    && IsUnset(Edition);
            }
        }

        /// <summary>
        /// Writes the fields as the members of a JSON object, in the fixed
        /// order of the properties above and under the key names given
        /// there. A field that is null or empty is left out, so the block
        /// never carries empty values; "pid" is written as a JSON number and
        /// only when it is positive. The writer has to be inside an object.
        /// </summary>
        internal void WriteTo(Utf8JsonWriter writer)
        {
            WriteStringIfSet(writer, "session_id", SessionId);
            WriteStringIfSet(writer, "recorded_by", RecordedBy);
            WriteStringIfSet(writer, "host", ComputerName);
            WriteStringIfSet(writer, "user", UserName);
            if (ProcessId > 0)
            {
                writer.WriteNumber("pid", ProcessId);
            }
            WriteStringIfSet(writer, "psversion", PSVersion);
            WriteStringIfSet(writer, "psedition", Edition);
        }

        private static bool IsUnset(string value)
        {
            return string.IsNullOrEmpty(value);
        }

        private static void WriteStringIfSet(Utf8JsonWriter writer, string key, string value)
        {
            if (!IsUnset(value))
            {
                writer.WriteString(key, value);
            }
        }
    }
}
