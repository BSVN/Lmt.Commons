using System;
using System.Globalization;
using System.Text;

namespace Bsn.Host.Interop
{
    /// <summary>
    /// JSON string writing for the cast file. The interop assembly targets
    /// netstandard2.0 and carries no JSON library, so the header and the
    /// event lines are built as text. Every string value passes through
    /// here, whether it is a header field (CastWriter) or part of the audit
    /// metadata block (AuditMetadata), which keeps the escaping of one line
    /// consistent no matter which writer produced a given value.
    /// </summary>
    internal static class JsonText
    {
        /// <summary>
        /// Returns text as a complete JSON string, surrounding quotes
        /// included.
        /// </summary>
        internal static string Quote(string text)
        {
            return "\"" + Escape(text) + "\"";
        }

        /// <summary>
        /// Returns the content of a JSON string for text, without the
        /// surrounding quotes: backslash and double quote are escaped, the
        /// named control characters use their short forms (\n, \r, ...) and
        /// every other control character its \u00XX form. All other
        /// characters pass through unchanged; the file itself is UTF-8.
        /// </summary>
        internal static string Escape(string text)
        {
            StringBuilder escaped = new StringBuilder(text.Length + 8);
            for (int i = 0; i < text.Length; i++)
            {
                char c = text[i];
                if (c == '\\') { escaped.Append("\\\\"); }
                else if (c == '"') { escaped.Append("\\\""); }
                else if (c == '\n') { escaped.Append("\\n"); }
                else if (c == '\r') { escaped.Append("\\r"); }
                else if (c == '\t') { escaped.Append("\\t"); }
                else if (c == '\b') { escaped.Append("\\b"); }
                else if (c == '\f') { escaped.Append("\\f"); }
                else if (c < 0x20 || c == 0x7f)
                {
                    escaped.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                }
                else { escaped.Append(c); }
            }
            return escaped.ToString();
        }
    }
}
