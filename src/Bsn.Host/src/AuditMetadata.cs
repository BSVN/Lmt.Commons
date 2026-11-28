using System.Text.Json;
using System.Text.Json.Serialization;

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
    /// block's shape: the key a field is written under is its
    /// JsonPropertyName, and System.Text.Json serializes the block from
    /// that, as a member of the header. Downstream readers
    /// (ConvertTo-BsnTranscript, the audit export) parse the block from the
    /// cast header; its key names are part of the recording format.
    ///
    /// A field that carries no value - null, an empty string, or a process
    /// id that is not positive - is left out of the block, so the block
    /// never holds empty values. An empty string and a non-positive process
    /// id are stored as "no value" when they are assigned.
    /// </summary>
    public sealed class AuditMetadata
    {
        private string sessionId;
        private string recordedBy;
        private string computerName;
        private string userName;
        private int processId;
        private string psVersion;
        private string edition;

        /// <summary>
        /// True when no field carries a value. The cast writers leave the
        /// "bsn" block out of the header for such an object. It says
        /// something about the block, but is not part of it.
        /// </summary>
        [JsonIgnore]
        public bool IsEmpty
        {
            get
            {
                return (this.sessionId == null)
                    && (this.recordedBy == null)
                    && (this.computerName == null)
                    && (this.userName == null)
                    && (this.processId == 0)
                    && (this.psVersion == null)
                    && (this.edition == null);
            }
        }

        /// <summary>
        /// GUID minted when the recording starts.
        /// </summary>
        [JsonPropertyName("session_id")]
        public string SessionId
        {
            get { return this.sessionId; }
            set { this.sessionId = TextOrNull(value); }
        }

        /// <summary>
        /// Module that made the recording, for example 'bsn.host 0.3.0'.
        /// </summary>
        [JsonPropertyName("recorded_by")]
        public string RecordedBy
        {
            get { return this.recordedBy; }
            set { this.recordedBy = TextOrNull(value); }
        }

        /// <summary>
        /// Machine the recorded session ran on.
        /// </summary>
        [JsonPropertyName("host")]
        public string ComputerName
        {
            get { return this.computerName; }
            set { this.computerName = TextOrNull(value); }
        }

        /// <summary>
        /// Account that started the recording.
        /// </summary>
        [JsonPropertyName("user")]
        public string UserName
        {
            get { return this.userName; }
            set { this.userName = TextOrNull(value); }
        }

        /// <summary>
        /// Process id of the PowerShell that made the recording, written as
        /// a JSON number and only when it is positive.
        /// </summary>
        [JsonPropertyName("pid")]
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)]
        public int ProcessId
        {
            get { return this.processId; }
            set { this.processId = (value > 0) ? value : 0; }
        }

        /// <summary>
        /// Version of the PowerShell that made the recording, for example
        /// '7.6.9'.
        /// </summary>
        [JsonPropertyName("psversion")]
        public string PSVersion
        {
            get { return this.psVersion; }
            set { this.psVersion = TextOrNull(value); }
        }

        /// <summary>
        /// Edition of the PowerShell that made the recording: 'Core' or
        /// 'Desktop'.
        /// </summary>
        [JsonPropertyName("psedition")]
        public string Edition
        {
            get { return this.edition; }
            set { this.edition = TextOrNull(value); }
        }

        private static string TextOrNull(string value)
        {
            return string.IsNullOrEmpty(value) ? null : value;
        }
    }
}
