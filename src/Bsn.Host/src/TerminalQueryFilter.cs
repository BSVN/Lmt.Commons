using System;
using System.Text;
using System.Text.RegularExpressions;

namespace Bsn.Host.Interop
{
    /// <summary>
    /// Streaming filter that removes response-eliciting terminal QUERY
    /// sequences from a recorded VT output stream (issue #20).
    ///
    /// Recorded TUI applications query the terminal they are attached to:
    /// XTWINOPS pixel-size requests (ESC[14t), DSR cursor-position requests
    /// (ESC[6n), device attributes (ESC[c, ESC[>c), XTVERSION (ESC[>0q),
    /// kitty keyboard protocol queries (ESC[?u), DECRQM mode requests and
    /// OSC default-color queries (ESC]10;?BEL, ESC]11;?BEL, ESC]4;n;?).
    /// Those queries are only meaningful while the ORIGINAL application is
    /// connected to the terminal - in a cast file they are dead payload that
    /// makes any player re-broadcast them, which causes the real terminal to
    /// write its answers into the console input buffer where they surface as
    /// typed text at the prompt (issue #20: '[4;600;1200t' after playback).
    ///
    /// The filter is applied by the recorder at CAPTURE time (CastWriter), so
    /// casts never contain the queries; the live proxy view is NOT affected.
    /// Parser state persists across Filter calls, handling sequences that span
    /// chunk boundaries. Set forms, answers and ordinary content are preserved:
    /// SGR, cursor movement, alternate screen, OSC titles, XTWINOPS SET forms
    /// (e.g. 'CSI 4;height;width t'), kitty push/pop and DECSCUSR.
    /// </summary>
    public sealed class TerminalQueryFilter
    {
        private enum ParseMode { Ground, Escape, Csi, Osc }
        private ParseMode mode = ParseMode.Ground;
        private readonly StringBuilder sequence = new StringBuilder(64);
        private bool escapeSeenInsideOsc;

        // Bounded pattern (S6444): the palette-query body is tiny and the
        // pattern has no nested quantifiers, but the timeout makes the
        // worst case explicit.
        private static readonly System.Text.RegularExpressions.Regex OscPaletteQueryRegex =
            new System.Text.RegularExpressions.Regex(
                "^\\x1B\\]4;[0-9]+;\\?$",
                System.Text.RegularExpressions.RegexOptions.Compiled,
                TimeSpan.FromMilliseconds(100));

        /// <summary>
        /// Filters one chunk of decoded VT text and returns the part that can
        /// be emitted. A trailing partial sequence is held back until the
        /// next call completes it.
        /// </summary>
        public string Filter(string text)
        {
            if (string.IsNullOrEmpty(text))
            {
                return string.Empty;
            }

            var output = new StringBuilder(text.Length);
            for (int i = 0; i < text.Length; i++)
            {
                ProcessChar(text[i], output);
            }

            return output.ToString();
        }

        /// <summary>
        /// Emits any held partial sequence verbatim (end of stream): a
        /// truncated trailing sequence is real recorded content and must not
        /// vanish.
        /// </summary>
        public string FlushRemaining()
        {
            string held = sequence.ToString();
            sequence.Clear();
            mode = ParseMode.Ground;
            escapeSeenInsideOsc = false;
            return held;
        }

        private void ProcessChar(char ch, StringBuilder output)
        {
            switch (mode)
            {
                case ParseMode.Ground:
                    if (ch == '\x1B')
                    {
                        BeginSequence(ch);
                    }
                    else
                    {
                        output.Append(ch);
                    }

                    return;

                case ParseMode.Escape:
                    sequence.Append(ch);
                    if (ch == '[')
                    {
                        mode = ParseMode.Csi;
                    }
                    else if (ch == ']')
                    {
                        mode = ParseMode.Osc;
                        escapeSeenInsideOsc = false;
                    }
                    else
                    {
                        // Other escape introducers (charset selection, ESC 7,
                        // ESC D ...) are not queries - emit verbatim.
                        EmitSequence(output);
                    }

                    return;

                case ParseMode.Csi:
                    if (ch == '\x1B')
                    {
                        // A new sequence starts before this one ended: emit
                        // the malformed one as-is and restart.
                        EmitSequence(output);
                        BeginSequence(ch);
                        return;
                    }

                    if (ch >= 0x40 && ch <= 0x7E)
                    {
                        // Final byte: keep or drop the whole sequence.
                        sequence.Append(ch);
                        if (IsDroppedCsi(sequence.ToString()))
                        {
                            ResetToGround();
                        }
                        else
                        {
                            EmitSequence(output);
                        }

                        return;
                    }

                    if (ch < 0x20)
                    {
                        // Control character inside a CSI: emit the sequence
                        // as-is and re-process the character in Ground mode.
                        EmitSequence(output);
                        ProcessChar(ch, output);
                        return;
                    }

                    sequence.Append(ch);
                    if (sequence.Length > 128)
                    {
                        // Malformed oversized sequence: emit as-is.
                        EmitSequence(output);
                    }

                    return;

                case ParseMode.Osc:
                    if (escapeSeenInsideOsc)
                    {
                        if (ch == '\\')
                        {
                            // ST (ESC \) terminator.
                            FinishOsc(output, "\x1B\\");
                            return;
                        }

                        sequence.Append('\x1B');
                        escapeSeenInsideOsc = false;
                    }

                    if (ch == '\x07')
                    {
                        // BEL terminator.
                        FinishOsc(output, "\x07");
                        return;
                    }

                    if (ch == '\x1B')
                    {
                        escapeSeenInsideOsc = true;
                        return;
                    }

                    sequence.Append(ch);
                    if (sequence.Length > 4096)
                    {
                        // Malformed oversized OSC: emit as-is.
                        EmitSequence(output);
                    }

                    return;
            }
        }

        private void BeginSequence(char firstChar)
        {
            sequence.Clear();
            sequence.Append(firstChar);
            mode = ParseMode.Escape;
        }

        private void EmitSequence(StringBuilder output)
        {
            output.Append(sequence.ToString());
            ResetToGround();
        }

        private void ResetToGround()
        {
            sequence.Clear();
            mode = ParseMode.Ground;
            escapeSeenInsideOsc = false;
        }

        private void FinishOsc(StringBuilder output, string terminator)
        {
            // sequence holds the full OSC including the 'ESC ]' introducer.
            string body = sequence.ToString();
            bool isQuery = body == "\x1B]10;?" || body == "\x1B]11;?" || OscPaletteQueryRegex.IsMatch(body);
            if (!isQuery)
            {
                output.Append(body);
                output.Append(terminator);
            }

            ResetToGround();
        }

        private static bool IsDroppedCsi(string sequence)
        {
            // sequence shape: ESC [ <params/intermediates> <final byte>
            string body = sequence.Substring(2, sequence.Length - 3);
            char finalByte = sequence[sequence.Length - 1];
            switch (finalByte)
            {
                case 'n':
                    return true;                                   // DSR / cursor-position report requests
                case 'c':
                    return true;                                   // DA1/DA2/DA3 capability queries
                case 'u':
                    return body.StartsWith("?");                   // kitty keyboard protocol query
                case 'q':
                    return body.StartsWith(">");                   // XTVERSION query (DECSCUSR ' q' is kept)
                case 'p':
                    return body.StartsWith("?");                   // DECRQM mode request
                case 't':
                    return body == "5" || body == "6" || body == "11" || body == "13" || body == "14" || body == "16" || body == "18";
                default:
                    return false;
            }
        }
    }
}