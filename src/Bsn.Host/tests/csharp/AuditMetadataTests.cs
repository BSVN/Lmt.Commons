using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using Bsn.Host.Interop;
using NUnit.Framework;

namespace Bsn.Host.Tests
{
    /// <summary>
    /// Unit tests for the capture-time audit metadata, the "bsn" block a
    /// recording stamps into its cast header. AuditMetadata.ToHeaderJson()
    /// is the single definition of the block's shape for both recording
    /// engines (the ConPTY CastWriter in this assembly on Windows, the
    /// script(1) conversion on Unix), and its readers parse the block back
    /// out of the cast header - so the key names, their order and the
    /// format are pinned byte for byte here, and the escaping is checked
    /// against an independent JSON parser.
    /// </summary>
    [TestFixture]
    public class AuditMetadataTests
    {
        private const string SessionId = "0f8a1b2c-3d4e-4f50-8192-a3b4c5d6e7f8";

        private static AuditMetadata FullMetadata()
        {
            return new AuditMetadata
            {
                SessionId = SessionId,
                RecordedBy = "bsn.host 0.3.0",
                ComputerName = "ws01",
                UserName = "jdoe",
                ProcessId = 4242,
                PSVersion = "7.6.9",
                Edition = "Core",
            };
        }

        // === block shape ===

        [Test]
        public void ToHeaderJson_IsEmpty_WhenNoFieldIsSet()
        {
            Assert.That(new AuditMetadata().ToHeaderJson(), Is.Empty);
        }

        [Test]
        public void ToHeaderJson_WritesEveryField_UnderTheBlockKeys_InFixedOrder()
        {
            string expected = "{\"session_id\":\"" + SessionId + "\",\"recorded_by\":\"bsn.host 0.3.0\""
                + ",\"host\":\"ws01\",\"user\":\"jdoe\",\"pid\":4242,\"psversion\":\"7.6.9\",\"psedition\":\"Core\"}";

            Assert.That(FullMetadata().ToHeaderJson(), Is.EqualTo(expected));
        }

        [Test]
        public void ToHeaderJson_IsOneCompactLine_WithNoWhitespaceOutsideStringValues()
        {
            string json = FullMetadata().ToHeaderJson();

            // The header must stay one line, whatever the values contain.
            Assert.That(json, Does.Not.Contain("\n"));
            Assert.That(json, Does.Not.Contain("\r"));

            // With every string literal removed, only the punctuation between
            // the fields is left plus the process id, which is a JSON number:
            // nothing but "key":value pairs separated by commas, and no
            // whitespace. (Values such as 'bsn.host 0.3.0' legitimately
            // contain spaces inside their quotes.)
            string structure = Regex.Replace(json, @"""(?:[^""\\]|\\.)*""", string.Empty);
            Assert.That(structure, Is.EqualTo("{:,:,:,:,:4242,:,:}"));
        }

        // === fields left out ===

        [Test]
        public void ToHeaderJson_LeavesOut_NullAndEmptyFields()
        {
            AuditMetadata metadata = new AuditMetadata
            {
                SessionId = "guid-1",
                RecordedBy = null,
                ComputerName = "ws01",
                UserName = string.Empty,
                PSVersion = null,
                Edition = string.Empty,
            };

            Assert.That(metadata.ToHeaderJson(), Is.EqualTo("{\"session_id\":\"guid-1\",\"host\":\"ws01\"}"));
        }

        [TestCase(0)]
        [TestCase(-1)]
        public void ToHeaderJson_LeavesOut_ANonPositiveProcessId(int processId)
        {
            AuditMetadata metadata = new AuditMetadata { UserName = "jdoe", ProcessId = processId };

            Assert.That(metadata.ToHeaderJson(), Is.EqualTo("{\"user\":\"jdoe\"}"));
        }

        [Test]
        public void ToHeaderJson_SeparatesTheRemainingFieldsCorrectly_WhenTheFirstLastAndMiddleOnesAreMissing()
        {
            // First and last property only: no leading or trailing comma.
            Assert.That(new AuditMetadata { SessionId = "a", Edition = "z" }.ToHeaderJson(),
                Is.EqualTo("{\"session_id\":\"a\",\"psedition\":\"z\"}"));

            // The process id alone.
            Assert.That(new AuditMetadata { ProcessId = 7 }.ToHeaderJson(), Is.EqualTo("{\"pid\":7}"));
        }

        // === escaping, shared with the rest of the header (JsonText) ===

        [TestCase("\\", "\\\\")]
        [TestCase("\"", "\\\"")]
        [TestCase("\n", "\\n")]
        [TestCase("\r", "\\r")]
        [TestCase("\t", "\\t")]
        [TestCase("\b", "\\b")]
        [TestCase("\f", "\\f")]
        [TestCase("\0", "\\u0000")]
        [TestCase("\x1B", "\\u001b")]
        [TestCase("\x1F", "\\u001f")]
        [TestCase("\x7F", "\\u007f")]
        public void ToHeaderJson_Escapes_SpecialAndControlCharacters(string value, string escaped)
        {
            AuditMetadata metadata = new AuditMetadata { UserName = "a" + value + "b" };

            Assert.That(metadata.ToHeaderJson(), Is.EqualTo("{\"user\":\"a" + escaped + "b\"}"));
        }

        [Test]
        public void ToHeaderJson_PassesOrdinaryTextThrough_Unchanged()
        {
            AuditMetadata metadata = new AuditMetadata { ComputerName = "O'Brien & <ws-01>", PSVersion = "7.6.9" };

            Assert.That(metadata.ToHeaderJson(), Is.EqualTo("{\"host\":\"O'Brien & <ws-01>\",\"psversion\":\"7.6.9\"}"));
        }

        [Test]
        public void ToHeaderJson_IsValidJson_ForAwkwardValues_AccordingToAnIndependentParser()
        {
            AuditMetadata metadata = new AuditMetadata
            {
                SessionId = "s\"\\\n",
                ComputerName = "J\u00F6rgner \u00E9",
                UserName = "\0\x1B\x7F",
                ProcessId = 4242,
            };
            string expectedUser = "\0\x1B\x7F";

            using (JsonDocument parsed = JsonDocument.Parse(metadata.ToHeaderJson()))
            {
                JsonElement root = parsed.RootElement;

                Assert.That(root.EnumerateObject().Select(property => property.Name),
                    Is.EqualTo(new[] { "session_id", "host", "user", "pid" }));
                Assert.That(root.GetProperty("session_id").GetString(), Is.EqualTo("s\"\\\n"));
                Assert.That(root.GetProperty("host").GetString(), Is.EqualTo("J\u00F6rgner \u00E9"));
                Assert.That(root.GetProperty("user").GetString(), Is.EqualTo(expectedUser));
                Assert.That(root.GetProperty("pid").GetInt32(), Is.EqualTo(4242));
            }
        }
    }
}
