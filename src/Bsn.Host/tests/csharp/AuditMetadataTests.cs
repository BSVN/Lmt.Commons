using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using Bsn.Host.Interop;
using NUnit.Framework;

namespace Bsn.Host.Tests
{
    /// <summary>
    /// Unit tests for the capture-time audit metadata, the "bsn" block a
    /// recording stamps into its cast header. The block is written by
    /// AuditMetadata inside CastJson.Header() - the header writer both
    /// recording engines share (the ConPTY CastWriter in this assembly on
    /// Windows, ConvertTo-BsnAsciicast for the script(1) engine on Unix) -
    /// and its readers parse it back out of the cast header. So the key
    /// names, their order and the format are pinned byte for byte here,
    /// through CastJson.Header(): the only way a block ever gets written.
    /// </summary>
    [TestFixture]
    public class AuditMetadataTests
    {
        private const string SessionId = "0f8a1b2c-3d4e-4f50-8192-a3b4c5d6e7f8";
        private const string Title = "Bsn.Host interactive transcript";

        // What the v2 header holds before the audit block (and after it,
        // when there is none), for the arguments Header() passes.
        private const string HeaderWithoutBlock =
            "{\"version\":2,\"width\":80,\"height\":24,\"timestamp\":1793895000,"
            + "\"title\":\"Bsn.Host interactive transcript\",\"env\":{\"SHELL\":\"pwsh\",\"TERM\":\"xterm-256color\"}}";

        // The same header without its closing brace: the point the audit
        // block is inserted at.
        private static readonly string HeaderUpToTheAuditBlock = HeaderWithoutBlock.Substring(0, HeaderWithoutBlock.Length - 1);

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

        private static string Header(AuditMetadata metadata, int castVersion)
        {
            return CastJson.Header(castVersion, 80, 24, 1793895000, "pwsh", Title, metadata);
        }

        /// <summary>
        /// The audit block member of the v2 header written for metadata,
        /// exactly as it appears in the file - ',"bsn":{...}' - or an empty
        /// string when the header carries no block.
        /// </summary>
        private static string BlockMember(AuditMetadata metadata)
        {
            string header = Header(metadata, 2);

            Assert.That(header, Does.StartWith(HeaderUpToTheAuditBlock));
            Assert.That(header, Does.EndWith("}"), "the closing brace of the header object");
            return header.Substring(HeaderUpToTheAuditBlock.Length, header.Length - HeaderUpToTheAuditBlock.Length - 1);
        }

        // === block shape ===

        [Test]
        public void Block_IsLeftOut_WhenNoMetadataObjectIsGiven()
        {
            Assert.That(Header(null, 2), Is.EqualTo(HeaderWithoutBlock));
        }

        [Test]
        public void Block_IsLeftOut_WhenNoFieldIsSet()
        {
            Assert.That(BlockMember(new AuditMetadata()), Is.Empty);
        }

        [Test]
        public void Block_WritesEveryField_UnderTheBlockKeys_InFixedOrder()
        {
            Assert.That(BlockMember(FullMetadata()),
                Is.EqualTo(",\"bsn\":{\"session_id\":\"" + SessionId + "\",\"recorded_by\":\"bsn.host 0.3.0\""
                    + ",\"host\":\"ws01\",\"user\":\"jdoe\",\"pid\":4242,\"psversion\":\"7.6.9\",\"psedition\":\"Core\"}"));
        }

        [Test]
        public void Block_IsTheLastMember_OfTheV2AndTheV3Header()
        {
            AuditMetadata metadata = FullMetadata();
            string member = BlockMember(metadata);

            Assert.That(Header(metadata, 2), Is.EqualTo(HeaderUpToTheAuditBlock + member + "}"));
            Assert.That(Header(metadata, 3),
                Is.EqualTo("{\"version\":3,\"term\":{\"cols\":80,\"rows\":24,\"type\":\"xterm-256color\"},\"timestamp\":1793895000,"
                    + "\"command\":\"pwsh\",\"title\":\"" + Title + "\",\"env\":{\"SHELL\":\"pwsh\",\"TERM\":\"xterm-256color\"}"
                    + member + "}"));
        }

        [Test]
        public void Block_IsCompact_WithNoWhitespaceOutsideStringValues()
        {
            // With every string literal removed, only the punctuation between
            // the fields is left plus the process id, which is a JSON number:
            // nothing but "key":value pairs separated by commas, and no
            // whitespace. (Values such as 'bsn.host 0.3.0' legitimately
            // contain spaces inside their quotes.)
            string structure = Regex.Replace(BlockMember(FullMetadata()), @"""(?:[^""\\]|\\.)*""", string.Empty);

            Assert.That(structure, Is.EqualTo(",:{:,:,:,:,:4242,:,:}"));
        }

        // === one field at a time ===

        public static IEnumerable<TestCaseData> FieldCases()
        {
            yield return new TestCaseData("SessionId", "x", "{\"session_id\":\"x\"}");
            yield return new TestCaseData("RecordedBy", "x", "{\"recorded_by\":\"x\"}");
            yield return new TestCaseData("ComputerName", "x", "{\"host\":\"x\"}");
            yield return new TestCaseData("UserName", "x", "{\"user\":\"x\"}");
            yield return new TestCaseData("ProcessId", 7, "{\"pid\":7}");
            yield return new TestCaseData("PSVersion", "x", "{\"psversion\":\"x\"}");
            yield return new TestCaseData("Edition", "x", "{\"psedition\":\"x\"}");
        }

        [TestCaseSource(nameof(FieldCases))]
        public void Block_IsWritten_ForAFieldThatIsSetAlone(string property, object value, string expectedBlock)
        {
            // A field that is set counts as content even when it is the only
            // one: IsEmpty() has to agree with WriteTo() on every field.
            AuditMetadata metadata = new AuditMetadata();
            typeof(AuditMetadata).GetProperty(property).SetValue(metadata, value);

            Assert.That(BlockMember(metadata), Is.EqualTo(",\"bsn\":" + expectedBlock));
        }

        [Test]
        public void EveryPublicProperty_HasAFieldCase()
        {
            // A new field needs a row in FieldCases() - and so the test above
            // - or it could be dropped from the block unnoticed.
            string[] covered = FieldCases().Select(caseData => (string)caseData.Arguments[0]).ToArray();

            Assert.That(typeof(AuditMetadata).GetProperties().Select(property => property.Name), Is.EquivalentTo(covered));
        }

        // === fields left out ===

        [Test]
        public void Block_LeavesOut_NullAndEmptyFields()
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

            Assert.That(BlockMember(metadata), Is.EqualTo(",\"bsn\":{\"session_id\":\"guid-1\",\"host\":\"ws01\"}"));
        }

        [TestCase(0)]
        [TestCase(-1)]
        public void Block_LeavesOut_ANonPositiveProcessId(int processId)
        {
            Assert.That(BlockMember(new AuditMetadata { UserName = "jdoe", ProcessId = processId }),
                Is.EqualTo(",\"bsn\":{\"user\":\"jdoe\"}"));
        }

        [Test]
        public void Block_SeparatesTheRemainingFieldsCorrectly_WhenTheFirstLastAndMiddleOnesAreMissing()
        {
            // First and last property only: no leading or trailing comma.
            Assert.That(BlockMember(new AuditMetadata { SessionId = "a", Edition = "z" }),
                Is.EqualTo(",\"bsn\":{\"session_id\":\"a\",\"psedition\":\"z\"}"));

            // The process id alone.
            Assert.That(BlockMember(new AuditMetadata { ProcessId = 7 }), Is.EqualTo(",\"bsn\":{\"pid\":7}"));
        }

        // === escaping (the header writer's, which the block shares) ===

        [TestCase("\\", "\\\\")]
        [TestCase("\"", "\\\"")]
        [TestCase("\n", "\\n")]
        [TestCase("\r", "\\r")]
        [TestCase("\t", "\\t")]
        [TestCase("\b", "\\b")]
        [TestCase("\f", "\\f")]
        [TestCase("\0", "\\u0000")]
        [TestCase("\x1B", "\\u001B")]
        [TestCase("\x7F", "\\u007F")]
        public void Block_Escapes_SpecialAndControlCharacters(string value, string escaped)
        {
            Assert.That(BlockMember(new AuditMetadata { UserName = "a" + value + "b" }),
                Is.EqualTo(",\"bsn\":{\"user\":\"a" + escaped + "b\"}"));
        }

        [Test]
        public void Block_LeavesOrdinaryTextAndNonAscii_Unescaped()
        {
            AuditMetadata metadata = new AuditMetadata { ComputerName = "J\u00F6rgner's <ws-01> & Co", PSVersion = "7.6.9" };

            Assert.That(BlockMember(metadata),
                Is.EqualTo(",\"bsn\":{\"host\":\"J\u00F6rgner's <ws-01> & Co\",\"psversion\":\"7.6.9\"}"));
        }

        // === read back ===

        [Test]
        public void Header_WithAwkwardValues_StaysOneLine_AndGivesAJsonReaderTheValuesBack()
        {
            string awkwardUser = "\0\x1B\x7F";
            AuditMetadata metadata = new AuditMetadata
            {
                SessionId = "s\"\\\n",
                ComputerName = "J\u00F6rgner \u00E9",
                UserName = awkwardUser,
                ProcessId = 4242,
            };

            string header = Header(metadata, 2);
            string rawControlCharacters = new string(header.Where(char.IsControl).ToArray());

            Assert.That(rawControlCharacters, Is.Empty, "control characters must not be left raw in the header: " + header);

            using (JsonDocument parsed = JsonDocument.Parse(header))
            {
                JsonElement block = parsed.RootElement.GetProperty("bsn");

                Assert.That(block.EnumerateObject().Select(property => property.Name),
                    Is.EqualTo(new[] { "session_id", "host", "user", "pid" }));
                Assert.That(block.GetProperty("session_id").GetString(), Is.EqualTo("s\"\\\n"));
                Assert.That(block.GetProperty("host").GetString(), Is.EqualTo("J\u00F6rgner \u00E9"));
                Assert.That(block.GetProperty("user").GetString(), Is.EqualTo(awkwardUser));
                Assert.That(block.GetProperty("pid").GetInt32(), Is.EqualTo(4242));
            }
        }
    }
}
