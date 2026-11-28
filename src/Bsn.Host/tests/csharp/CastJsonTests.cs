using System;
using System.Linq;
using System.Text.Json;
using Bsn.Host.Interop;
using NUnit.Framework;

namespace Bsn.Host.Tests
{
    /// <summary>
    /// Unit tests for CastJson, the writer of a cast file's JSON lines - the
    /// header and the events - that both recording engines share (the ConPTY
    /// CastWriter in this assembly on Windows, ConvertTo-BsnAsciicast for the
    /// script(1) engine on Unix). Players and the module's own readers parse
    /// these lines, so their layout is pinned byte for byte. The exact
    /// expectations are written out as literals on purpose: JsonDocument,
    /// which the round-trip tests use, is the same library that wrote the
    /// lines and is no independent judge of the escaping.
    /// </summary>
    [TestFixture]
    public class CastJsonTests
    {
        private const long Timestamp = 1793895000;
        private const string Title = "Bsn.Host interactive transcript";

        // === header ===

        [Test]
        public void Header_WritesTheAsciicastV2Layout()
        {
            Assert.That(CastJson.Header(2, 80, 24, Timestamp, "pwsh", Title, null),
                Is.EqualTo("{\"version\":2,\"width\":80,\"height\":24,\"timestamp\":1793895000,"
                    + "\"title\":\"Bsn.Host interactive transcript\",\"env\":{\"SHELL\":\"pwsh\",\"TERM\":\"xterm-256color\"}}"));
        }

        [Test]
        public void Header_WritesTheAsciicastV3Layout()
        {
            Assert.That(CastJson.Header(3, 120, 30, Timestamp, "pwsh -NoProfile", Title, null),
                Is.EqualTo("{\"version\":3,\"term\":{\"cols\":120,\"rows\":30,\"type\":\"xterm-256color\"},\"timestamp\":1793895000,"
                    + "\"command\":\"pwsh -NoProfile\",\"title\":\"Bsn.Host interactive transcript\","
                    + "\"env\":{\"SHELL\":\"pwsh -NoProfile\",\"TERM\":\"xterm-256color\"}}"));
        }

        [TestCase(2)]
        [TestCase(3)]
        public void Header_IsOneLine_OfValidJson(int castVersion)
        {
            string header = CastJson.Header(castVersion, 80, 24, Timestamp, "pwsh", Title, null);

            AssertHasNoRawControlCharacters(header);
            using (JsonDocument parsed = JsonDocument.Parse(header))
            {
                JsonElement root = parsed.RootElement;
                Assert.That(root.GetProperty("version").GetInt32(), Is.EqualTo(castVersion));
                Assert.That(root.GetProperty("timestamp").GetInt64(), Is.EqualTo(Timestamp));
                Assert.That(root.GetProperty("title").GetString(), Is.EqualTo(Title));
                Assert.That(root.GetProperty("env").GetProperty("SHELL").GetString(), Is.EqualTo("pwsh"));
                Assert.That(root.GetProperty("env").GetProperty("TERM").GetString(), Is.EqualTo("xterm-256color"));
                Assert.That(root.TryGetProperty("bsn", out JsonElement _), Is.False, "a null AuditMetadata leaves the block out");
            }
        }

        [Test]
        public void Header_Refuses_AnUnknownCastVersion()
        {
            // The layout is one of two; a header must not claim another version.
            Assert.That(delegate { CastJson.Header(1, 80, 24, Timestamp, "pwsh", Title, null); }, Throws.TypeOf<ArgumentOutOfRangeException>());
        }

        [Test]
        public void Header_Escapes_TheShellName()
        {
            string header = CastJson.Header(3, 80, 24, Timestamp, "a\"b\\c\nd", Title, null);

            Assert.That(header, Does.Contain("\"command\":\"a\\\"b\\\\c\\nd\",\"title\":"));
            Assert.That(header, Does.Contain("\"env\":{\"SHELL\":\"a\\\"b\\\\c\\nd\",\"TERM\":\"xterm-256color\"}"));
            AssertHasNoRawControlCharacters(header);
        }

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
        public void Header_Escapes_SpecialAndControlCharacters_InStringValues(string value, string escaped)
        {
            string header = CastJson.Header(2, 80, 24, Timestamp, "pwsh", "a" + value + "b", null);

            Assert.That(header, Does.Contain("\"title\":\"a" + escaped + "b\""));
            AssertHasNoRawControlCharacters(header);
        }

        [Test]
        public void Header_LeavesNonAsciiAndOrdinaryPunctuation_Unescaped()
        {
            // Raw UTF-8, not \uXXXX: the file stays readable, and a byte
            // count is all a reader needs to make sense of a line.
            string title = "J\u00F6rg's <tab> & caf\u00E9 \u2500";

            Assert.That(CastJson.Header(2, 80, 24, Timestamp, "pwsh", title, null), Does.Contain("\"title\":\"" + title + "\""));
        }

        [Test]
        public void Header_WritesANullShellNameOrTitle_AsAnEmptyString()
        {
            Assert.That(CastJson.Header(3, 80, 24, Timestamp, null, null, null),
                Does.Contain("\"command\":\"\",\"title\":\"\",\"env\":{\"SHELL\":\"\",\"TERM\":\"xterm-256color\"}"));
        }

        // === events ===

        [TestCase(0.5, "o", "hello", "[0.5,\"o\",\"hello\"]")]
        [TestCase(0, "x", "7", "[0,\"x\",\"7\"]")]
        [TestCase(1.25, "r", "120x30", "[1.25,\"r\",\"120x30\"]")]
        [TestCase(0.125, "i", "", "[0.125,\"i\",\"\"]")]
        public void Event_WritesTheCompactTriple(double time, string eventType, string text, string expected)
        {
            Assert.That(CastJson.Event(time, 6, eventType, text), Is.EqualTo(expected));
        }

        [TestCase(0.1234567, 6, "0.123457")]
        [TestCase(0.1234567, 3, "0.123")]
        [TestCase(0.1 + 0.2, 3, "0.3")]
        [TestCase(1, 6, "1")]
        [TestCase(0.0004, 3, "0")]
        [TestCase(12.5, 3, "12.5")]
        public void Event_RoundsTheTime_ToTheRequestedDecimals(double time, int timeDecimals, string expectedTime)
        {
            // 0.1 + 0.2 is the floating point sum 0.30000000000000004: an
            // interval of a v3 cast must still reach the file as 0.3.
            Assert.That(CastJson.Event(time, timeDecimals, "o", string.Empty), Is.EqualTo("[" + expectedTime + ",\"o\",\"\"]"));
        }

        [Test]
        public void Event_Escapes_TerminalOutput_AndStaysOneLine()
        {
            // What a TUI app emits: color escapes, a line break, a tab, a
            // box-drawing character and text that needs quoting.
            string text = "\x1B[1;32mok\x1B[0m\r\nsay \"hi\"\t\u2500";

            string line = CastJson.Event(1.5, 6, "o", text);

            Assert.That(line, Is.EqualTo("[1.5,\"o\",\"\\u001B[1;32mok\\u001B[0m\\r\\nsay \\\"hi\\\"\\t\u2500\"]"));
            AssertHasNoRawControlCharacters(line);
        }

        [Test]
        public void Event_WritesANullEventTypeOrText_AsAnEmptyString()
        {
            Assert.That(CastJson.Event(0, 6, null, null), Is.EqualTo("[0,\"\",\"\"]"));
        }

        [Test]
        public void Event_WritesAWholeNumber_WhenNoDecimalsAreAskedFor()
        {
            Assert.That(CastJson.Event(12.5, 0, "o", string.Empty), Is.EqualTo("[13,\"o\",\"\"]"));
        }

        [Test]
        public void Event_Refuses_ATimeThatIsNotAFiniteNumber()
        {
            // Neither is a JSON number, and the text would reach the file as is.
            Assert.That(delegate { CastJson.Event(double.NaN, 6, "o", string.Empty); }, Throws.TypeOf<ArgumentOutOfRangeException>());
            Assert.That(delegate { CastJson.Event(double.PositiveInfinity, 6, "o", string.Empty); }, Throws.TypeOf<ArgumentOutOfRangeException>());
            Assert.That(delegate { CastJson.Event(double.NegativeInfinity, 6, "o", string.Empty); }, Throws.TypeOf<ArgumentOutOfRangeException>());
        }

        [Test]
        public void Event_Refuses_ANegativeNumberOfDecimals()
        {
            Assert.That(delegate { CastJson.Event(1, -1, "o", string.Empty); }, Throws.TypeOf<ArgumentOutOfRangeException>());
        }

        // === read back ===

        [Test]
        public void Lines_GiveAJsonReader_TheOriginalTextBack()
        {
            string text = "\0\x1B\x7F \" \\ \n \u00E9 \u2500 \uD83D\uDE00";
            AuditMetadata metadata = new AuditMetadata { UserName = text, ProcessId = 4242 };
            string header = CastJson.Header(2, 80, 24, Timestamp, "pwsh", text, metadata);

            using (JsonDocument parsedHeader = JsonDocument.Parse(header))
            {
                JsonElement root = parsedHeader.RootElement;
                Assert.That(root.GetProperty("title").GetString(), Is.EqualTo(text));
                Assert.That(root.GetProperty("bsn").GetProperty("user").GetString(), Is.EqualTo(text));
                Assert.That(root.GetProperty("bsn").GetProperty("pid").GetInt32(), Is.EqualTo(4242));
            }

            using (JsonDocument parsedEvent = JsonDocument.Parse(CastJson.Event(2.25, 6, "o", text)))
            {
                JsonElement element = parsedEvent.RootElement;
                Assert.That(element.GetArrayLength(), Is.EqualTo(3));
                Assert.That(element[0].GetDouble(), Is.EqualTo(2.25));
                Assert.That(element[1].GetString(), Is.EqualTo("o"));
                Assert.That(element[2].GetString(), Is.EqualTo(text));
            }
        }

        /// <summary>
        /// A cast file is JSON lines: a raw line break would split a line in
        /// two, and JSON requires every other control character to be escaped
        /// as well.
        /// </summary>
        private static void AssertHasNoRawControlCharacters(string line)
        {
            string raw = new string(line.Where(char.IsControl).ToArray());

            Assert.That(raw, Is.Empty, "control characters must not be left raw in the line: " + line);
        }
    }
}
