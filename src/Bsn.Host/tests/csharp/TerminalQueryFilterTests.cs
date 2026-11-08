using Bsn.Host.Interop;
using NUnit.Framework;

namespace Bsn.Host.Tests
{
    /// <summary>
    /// Unit tests for the capture-time query-sequence filter (issue #20:
    /// https://github.com/BSVN/Lmt.Commons/issues/20). Response-eliciting
    /// terminal queries (XTWINOPS pixel size, DSR, DA, kitty keyboard,
    /// XTVERSION, DECRQM, OSC default-color) must never reach a cast file:
    /// any player re-broadcasts them and the real terminal answers into the
    /// console input buffer, where PSReadLine consumes the responses as
    /// typed text at the prompt.
    /// </summary>
    [TestFixture]
    public class TerminalQueryFilterTests
    {
        private const string Esc = "\x1B";
        private const string Bel = "\x07";
        private const string St = "\x1B\\";

        private static TerminalQueryFilter NewFilter()
        {
            return new TerminalQueryFilter();
        }

        // === response-eliciting query sequences are dropped ===

        [Test]
        public void Drops_Xtwinops_PixelSizeQuery_TheReported_Artifact()
        {
            Assert.That(NewFilter().Filter(Esc + "[14t"), Is.Empty);
        }

        [TestCase("6n")]
        [TestCase("?6n")]
        [TestCase("0n")]
        public void Drops_Dsr_CursorPosition_ReportRequests(string body)
        {
            Assert.That(NewFilter().Filter(Esc + "[" + body), Is.Empty);
        }

        [TestCase("c")]
        [TestCase("0c")]
        [TestCase(">c")]
        [TestCase(">85;100c")]
        [TestCase("=67;84;1c")]
        public void Drops_DeviceAttribute_CapabilityQueries(string body)
        {
            Assert.That(NewFilter().Filter(Esc + "[" + body), Is.Empty);
        }

        [TestCase(">0q")]
        [TestCase(">q")]
        public void Drops_Xtversion_Query(string body)
        {
            Assert.That(NewFilter().Filter(Esc + "[" + body), Is.Empty);
        }

        [Test]
        public void Drops_KittyKeyboard_ProtocolQuery()
        {
            Assert.That(NewFilter().Filter(Esc + "[?u"), Is.Empty);
        }

        [Test]
        public void Drops_Decrqm_Dec_ModeRequest()
        {
            Assert.That(NewFilter().Filter(Esc + "[?2026$p"), Is.Empty);
        }

        [TestCase("5t")]
        [TestCase("6t")]
        [TestCase("11t")]
        [TestCase("13t")]
        [TestCase("14t")]
        [TestCase("16t")]
        [TestCase("18t")]
        public void Drops_Every_Xtwinops_SingleParameter_ReportRequest(string suffix)
        {
            Assert.That(NewFilter().Filter(Esc + "[" + suffix), Is.Empty);
        }

        [TestCase("10;?", Bel)]
        [TestCase("11;?", Bel)]
        [TestCase("10;?", St)]
        [TestCase("11;?", St)]
        public void Drops_Osc_DefaultColor_Queries(string body, string terminator)
        {
            Assert.That(NewFilter().Filter(Esc + "]" + body + terminator), Is.Empty);
        }

        [TestCase("4;1;?", Bel)]
        [TestCase("4;12;?", Bel)]
        [TestCase("4;1;?", St)]
        public void Drops_Osc_Palette_Queries(string body, string terminator)
        {
            Assert.That(NewFilter().Filter(Esc + "]" + body + terminator), Is.Empty);
        }

        // === set forms, answers and ordinary content are preserved ===

        [TestCase("4;600;1200t")]
        [TestCase("8;24;80t")]
        [TestCase("3;0t")]
        public void Keeps_Xtwinops_SetForms(string suffix)
        {
            var sequence = Esc + "[" + suffix;
            Assert.That(NewFilter().Filter(sequence), Is.EqualTo(sequence));
        }

        [TestCase(Esc + "[38;2;255;0;0mstyled" + Esc + "[0m")]
        [TestCase(Esc + "[2;3Hcursor move")]
        [TestCase(Esc + "[?1049h" + Esc + "[?1049l")]
        [TestCase(Esc + "]0;window title" + Bel)]
        [TestCase("hello ─ ╭ world")]
        [TestCase("plain text\r\nwith lines")]
        public void Keeps_Ordinary_Playback_Content(string text)
        {
            Assert.That(NewFilter().Filter(text), Is.EqualTo(text));
        }

        [Test]
        public void Keeps_Decrpm_Answer_Form_A_Report_Not_A_Request()
        {
            var answer = Esc + "[?2026;2$y";
            Assert.That(NewFilter().Filter(answer), Is.EqualTo(answer));
        }

        [Test]
        public void Keeps_Decscusr_CursorStyle_SpaceIntermediate_NoGT_Prefix()
        {
            var cursorStyle = Esc + "[3 q";
            Assert.That(NewFilter().Filter(cursorStyle), Is.EqualTo(cursorStyle));
        }

        // === chunk boundaries: the parser state persists across Filter calls ===

        [Test]
        public void Drops_Query_Sequence_Split_Across_Two_Chunks()
        {
            var filter = NewFilter();
            var part1 = filter.Filter(Esc + "[1");
            var part2 = filter.Filter("4t");
            Assert.That(part1 + part2, Is.Empty);
        }

        [Test]
        public void Drops_Query_Sequence_Split_MidParameter()
        {
            var filter = NewFilter();
            var part1 = filter.Filter(Esc + "[?2");
            var part2 = filter.Filter("026$p");
            Assert.That(part1 + part2, Is.Empty);
        }

        [Test]
        public void Drops_Osc_Query_Split_Across_Three_Chunks()
        {
            var filter = NewFilter();
            var part1 = filter.Filter(Esc + "]");
            var part2 = filter.Filter("11;");
            var part3 = filter.Filter("?" + Bel);
            Assert.That(part1 + part2 + part3, Is.Empty);
        }

        [Test]
        public void Keeps_Kept_Sequence_Split_Across_Chunks()
        {
            var filter = NewFilter();
            var part1 = filter.Filter(Esc + "[38");
            var part2 = filter.Filter(";2;1;2;3m");
            Assert.That(part1 + part2, Is.EqualTo(Esc + "[38;2;1;2;3m"));
        }

        [Test]
        public void Emits_Content_Before_And_After_A_Query_Split_Arbitrarily()
        {
            var filter = NewFilter();
            var collected = new System.Text.StringBuilder();
            foreach (var chunk in new[] { "before", Esc + "[1", "4t", "middle", Esc + "[6n", "after" })
            {
                collected.Append(filter.Filter(chunk));
            }

            Assert.That(collected.ToString(), Is.EqualTo("beforemiddleafter"));
        }

        // === end-of-stream handling ===

        [Test]
        public void FlushRemaining_Emits_A_Held_Lone_Esc_As_Real_Content()
        {
            var filter = NewFilter();
            Assert.That(filter.Filter(Esc), Is.Empty);   // held: could become a sequence
            Assert.That(filter.FlushRemaining(), Is.EqualTo(Esc));
        }

        [Test]
        public void FlushRemaining_Emits_A_Held_Partial_Sequence_As_Real_Content()
        {
            var filter = NewFilter();
            var partial = Esc + "[94";
            Assert.That(filter.Filter(partial), Is.Empty);   // held: could still complete
            Assert.That(filter.FlushRemaining(), Is.EqualTo(partial));
        }

        [Test]
        public void Continues_Filtering_Correctly_After_A_Flush()
        {
            var filter = NewFilter();
            Assert.That(filter.Filter(Esc), Is.Empty);
            Assert.That(filter.FlushRemaining(), Is.EqualTo(Esc));
            Assert.That(filter.Filter(Esc + "[14t"), Is.Empty);   // still drops queries after a flush
        }

        // === realistic mixed streams ===

        [Test]
        public void Scrubs_Queries_Inside_Mixed_Stream_While_Preserving_The_Rest()
        {
            var filter = NewFilter();
            var mixed = "START" + Esc + "[14t" + "MIDDLE" + Esc + "[6n" + "─ ╭ ─" + Esc + "]11;?" + Bel + "END";
            Assert.That(filter.Filter(mixed), Is.EqualTo("STARTMIDDLE─ ╭ ─END"));
        }

        [Test]
        public void Handles_Empty_Input()
        {
            Assert.That(NewFilter().Filter(string.Empty), Is.Empty);
        }
    }
}
