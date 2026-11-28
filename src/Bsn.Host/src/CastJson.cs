using System;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Bsn.Host.Interop
{
    /// <summary>
    /// Writes the JSON lines of an asciicast v2/v3 file - the header line and
    /// the event lines - with System.Text.Json, for BOTH recording engines:
    /// the ConPTY CastWriter in this assembly on Windows, and
    /// ConvertTo-BsnAsciicast (PowerShell) for the script(1) engine on Unix.
    /// One writer keeps the two engines' files identical in structure and
    /// escaping.
    ///
    /// Every line is one compact JSON value: no whitespace between elements,
    /// culture-invariant numbers, raw UTF-8 text. Strings are escaped by
    /// JavaScriptEncoder.UnsafeRelaxedJsonEscaping, which escapes quotes,
    /// backslashes and control characters and leaves every other character -
    /// including non-ASCII - as it is. ("Unsafe" refers to embedding the
    /// output in HTML; a cast file is read by terminal players, not
    /// browsers.) Event times are formatted by this class and written as
    /// given, so the time format of a cast file is the same whatever
    /// PowerShell, and whatever version of the library, wrote it.
    ///
    /// The header's layout is declared on the CastHeader type: the key of
    /// each member is its JsonPropertyName, a member that is null is left
    /// out, and System.Text.Json serializes the header from that.
    ///
    /// System.Text.Json is a NuGet dependency of this assembly. PowerShell 7
    /// binds this assembly to the copy it ships with itself, and only when
    /// that is at least the version this assembly was built against; Windows
    /// PowerShell 5.1 has none and uses the copies shipped in the module's
    /// lib/ folder. So this class may only use members that exist in the
    /// referenced version, and must format numbers itself: the copy that
    /// runs on .NET Framework prints 0.1 as 0.10000000000000001.
    /// </summary>
    public static class CastJson
    {
        private const string TerminalType = "xterm-256color";

        private static readonly JsonWriterOptions WriterOptions = new JsonWriterOptions
        {
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
        };

        // The header is serialized through these options, with the encoder
        // the event lines are written with: the whole file is escaped one way.
        private static readonly JsonSerializerOptions HeaderJsonOptions = new JsonSerializerOptions
        {
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
        };

        /// <summary>
        /// The members are declared in the order the header carries them.
        /// Version 2 records the terminal size as "width"/"height", version 3
        /// as a "term" object and additionally the command; the members of the
        /// other version stay null and are left out.
        /// </summary>
        private sealed class CastHeader
        {
            [JsonPropertyName("version")]
            public int Version { get; set; }

            [JsonPropertyName("width")]
            public int? Width { get; set; }

            [JsonPropertyName("height")]
            public int? Height { get; set; }

            [JsonPropertyName("term")]
            public CastTerminalSize Term { get; set; }

            [JsonPropertyName("timestamp")]
            public long Timestamp { get; set; }

            [JsonPropertyName("command")]
            public string Command { get; set; }

            [JsonPropertyName("title")]
            public string Title { get; set; }

            [JsonPropertyName("env")]
            public CastEnvironment Environment { get; set; }

            [JsonPropertyName("bsn")]
            public AuditMetadata AuditMetadata { get; set; }
        }

        private sealed class CastTerminalSize
        {
            [JsonPropertyName("cols")]
            public int Columns { get; set; }

            [JsonPropertyName("rows")]
            public int Rows { get; set; }

            [JsonPropertyName("type")]
            public string Type { get; set; }
        }

        private sealed class CastEnvironment
        {
            [JsonPropertyName("SHELL")]
            public string Shell { get; set; }

            [JsonPropertyName("TERM")]
            public string Term { get; set; }
        }

        /// <summary>
        /// Returns the header line of a cast file, without the trailing
        /// newline. castVersion selects the layout: 2 records the terminal
        /// size as "width"/"height", 3 as a "term" object and additionally
        /// records shellName as "command". Both record shellName as env.SHELL
        /// and xterm-256color as "term".type and env.TERM. timestamp is the
        /// recording's start as Unix epoch seconds. A null shellName or title
        /// is written as an empty string.
        ///
        /// When auditMetadata is given and carries any value, it is written as
        /// the last member, under the "bsn" key (see AuditMetadata). A null
        /// object, or one with nothing set, leaves the member out.
        /// </summary>
        public static string Header(int castVersion, int width, int height, long timestamp, string shellName, string title, AuditMetadata auditMetadata)
        {
            if ((castVersion != 2) && (castVersion != 3))
            {
                throw new ArgumentOutOfRangeException(nameof(castVersion), "An asciicast file is either version 2 or version 3.");
            }
            string shell = shellName ?? string.Empty;
            CastHeader header = new CastHeader();
            header.Version = castVersion;
            header.Timestamp = timestamp;
            header.Title = title ?? string.Empty;
            header.Environment = new CastEnvironment { Shell = shell, Term = TerminalType };
            if (castVersion == 3)
            {
                header.Term = new CastTerminalSize { Columns = width, Rows = height, Type = TerminalType };
                header.Command = shell;
            }
            else
            {
                header.Width = width;
                header.Height = height;
            }
            if ((auditMetadata != null) && !auditMetadata.IsEmpty)
            {
                header.AuditMetadata = auditMetadata;
            }
            return Serialize(delegate (Utf8JsonWriter writer)
            {
                JsonSerializer.Serialize(writer, header, HeaderJsonOptions);
            });
        }

        /// <summary>
        /// Returns one event line, without the trailing newline, as the array
        /// [time,eventType,text] - "o"/"i" output and input events carry the
        /// terminal text, "r" events a "cols x rows" size and "x" events the
        /// exit status. time is written as a JSON number with at most
        /// timeDecimals decimals and no trailing zeros (the engines pass 6 for
        /// v2 and 3 for v3). This class formats the number itself: left to
        /// the library, the same time would reach the file as 0.1 on one
        /// runtime and as 0.10000000000000001 on another. A null eventType
        /// or text is written as an empty string.
        /// </summary>
        public static string Event(double time, int timeDecimals, string eventType, string text)
        {
            if (double.IsNaN(time) || double.IsInfinity(time))
            {
                // Neither is a JSON number, and the text would reach the file as is.
                throw new ArgumentOutOfRangeException(nameof(time), "An event time has to be a finite number.");
            }
            if (timeDecimals < 0)
            {
                throw new ArgumentOutOfRangeException(nameof(timeDecimals));
            }
            // Up to timeDecimals decimals, no thousands separator, and '.'
            // as the decimal mark whatever the culture is.
            string format = (timeDecimals == 0) ? "0" : "0." + new string('#', timeDecimals);
            string timeText = time.ToString(format, CultureInfo.InvariantCulture);
            return Serialize(delegate (Utf8JsonWriter writer)
            {
                writer.WriteStartArray();
                writer.WriteRawValue(timeText, true);
                writer.WriteStringValue(eventType ?? string.Empty);
                writer.WriteStringValue(text ?? string.Empty);
                writer.WriteEndArray();
            });
        }

        /// <summary>
        /// Runs write on a Utf8JsonWriter over an in-memory buffer and returns
        /// what it wrote, as one line of UTF-8 text.
        /// </summary>
        private static string Serialize(Action<Utf8JsonWriter> write)
        {
            using (MemoryStream buffer = new MemoryStream())
            {
                using (Utf8JsonWriter writer = new Utf8JsonWriter(buffer, WriterOptions))
                {
                    write(writer);
                    writer.Flush();
                }
                return Encoding.UTF8.GetString(buffer.ToArray());
            }
        }
    }
}
