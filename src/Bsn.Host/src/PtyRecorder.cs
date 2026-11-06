using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Bsn.Host.Interop
{
    /// <summary>
    /// Result of a pseudo-console recording session.
    /// </summary>
    public class RecordingResult
    {
        public int ExitCode { get; set; }
        public double DurationSec { get; set; }
        public bool StoppedByRequest { get; set; }
    }

    /// <summary>
    /// Records a command line inside a Windows pseudo-console (ConPTY), teeing
    /// the VT stream with timestamps into an asciicast v2 file. Modelled on the
    /// EchoCon sample from the microsoft/terminal repository.
    /// </summary>
    public static class PtyRecorder
    {
        private const int STD_INPUT_HANDLE = -10;
        private const int STD_OUTPUT_HANDLE = -11;
        private const uint ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200;
        private const uint WAIT_OBJECT_0 = 0;
        private const uint WAIT_TIMEOUT = 258;
        private static readonly IntPtr PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = (IntPtr)0x00020016;
        private const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;

        [StructLayout(LayoutKind.Sequential)]
        private struct COORD
        {
            public short X;
            public short Y;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SMALL_RECT
        {
            public short Left;
            public short Top;
            public short Right;
            public short Bottom;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct CONSOLE_SCREEN_BUFFER_INFO
        {
            public COORD dwSize;
            public COORD dwCursorPosition;
            public ushort wAttributes;
            public SMALL_RECT srWindow;
            public COORD dwMaximumWindowSize;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO
        {
            public int cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public int dwX;
            public int dwY;
            public int dwXSize;
            public int dwYSize;
            public int dwXCountChars;
            public int dwYCountChars;
            public int dwFillAttribute;
            public int dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct STARTUPINFOEX
        {
            public STARTUPINFO StartupInfo;
            public IntPtr lpAttributeList;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public int dwProcessId;
            public int dwThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SECURITY_ATTRIBUTES
        {
            public int nLength;
            public IntPtr lpSecurityDescriptor;
            public bool bInheritHandle;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GetStdHandle(int nStdHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetConsoleScreenBufferInfo(IntPtr hConsoleOutput, out CONSOLE_SCREEN_BUFFER_INFO lpConsoleScreenBufferInfo);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CreatePipe(out IntPtr hReadPipe, out IntPtr hWritePipe, ref SECURITY_ATTRIBUTES lpPipeAttributes, uint nSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern int CreatePseudoConsole(COORD size, IntPtr hInput, IntPtr hOutput, uint dwFlags, out IntPtr phPC);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern int ResizePseudoConsole(IntPtr hPC, COORD size);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern void ClosePseudoConsole(IntPtr hPC);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags, IntPtr attribute, IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool CreateProcess(string lpApplicationName, StringBuilder lpCommandLine, IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFOEX lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool ReadFile(IntPtr hFile, byte[] lpBuffer, uint nNumberOfBytesToRead, out uint lpNumberOfBytesRead, IntPtr lpOverlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool WriteFile(IntPtr hFile, byte[] lpBuffer, uint nNumberOfBytesToRead, out uint lpNumberOfBytesRead, IntPtr lpOverlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CancelIoEx(IntPtr hFile, IntPtr lpOverlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeleteProcThreadAttributeList(IntPtr lpAttributeList);

        /// <summary>
        /// Runs commandLine inside a pseudo-console, proxying to the real console and
        /// recording to castPath (asciicast v2 or v3 depending on castVersion). When
        /// stopFilePath is non-empty, creating that file terminates the recorded process
        /// and finalizes the recording (the Stop-InteractiveTranscript signaling channel).
        /// </summary>
        public static RecordingResult Run(string commandLine, string castPath, bool recordInput, string shellName, string stopFilePath, int castVersion)
        {
            IntPtr hRealIn = GetStdHandle(STD_INPUT_HANDLE);
            IntPtr hRealOut = GetStdHandle(STD_OUTPUT_HANDLE);

            uint savedInputMode;
            bool hadConsoleMode = GetConsoleMode(hRealIn, out savedInputMode);

            short width = 120;
            short height = 30;
            CONSOLE_SCREEN_BUFFER_INFO bufferInfo;
            if (GetConsoleScreenBufferInfo(hRealOut, out bufferInfo))
            {
                short candidateWidth = (short)(bufferInfo.srWindow.Right - bufferInfo.srWindow.Left + 1);
                short candidateHeight = (short)(bufferInfo.srWindow.Bottom - bufferInfo.srWindow.Top + 1);
                if (candidateWidth > 0) { width = candidateWidth; }
                if (candidateHeight > 0) { height = candidateHeight; }
            }

            SECURITY_ATTRIBUTES security = new SECURITY_ATTRIBUTES();
            security.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
            security.bInheritHandle = false;

            IntPtr pipeInRead = IntPtr.Zero;
            IntPtr pipeInWrite = IntPtr.Zero;
            IntPtr pipeOutRead = IntPtr.Zero;
            IntPtr pipeOutWrite = IntPtr.Zero;
            IntPtr pseudoConsole = IntPtr.Zero;
            IntPtr attributeList = IntPtr.Zero;
            IntPtr childProcess = IntPtr.Zero;
            IntPtr childThread = IntPtr.Zero;

            Stopwatch clock = Stopwatch.StartNew();
            CastWriter cast = null;
            Thread outputThread = null;
            Thread inputThread = null;
            PumpState state = new PumpState();
            bool stoppedByRequest = false;

            try
            {
                if (!CreatePipe(out pipeInRead, out pipeInWrite, ref security, 0)) { throw Win32Error("CreatePipe"); }
                if (!CreatePipe(out pipeOutRead, out pipeOutWrite, ref security, 0)) { throw Win32Error("CreatePipe"); }

                COORD consoleSize = new COORD();
                consoleSize.X = width;
                consoleSize.Y = height;

                int hr = CreatePseudoConsole(consoleSize, pipeInRead, pipeOutWrite, 0, out pseudoConsole);
                if (hr != 0)
                {
                    throw new InvalidOperationException("CreatePseudoConsole failed with HRESULT 0x" + hr.ToString("X8", CultureInfo.InvariantCulture));
                }

                // The PTY-side ends were duplicated into conhost; closing our copies lets
                // the output pump observe EOF when the pseudo console closes (EchoCon pattern).
                CloseHandle(pipeInRead);
                pipeInRead = IntPtr.Zero;
                CloseHandle(pipeOutWrite);
                pipeOutWrite = IntPtr.Zero;

                IntPtr attributeListSize = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attributeListSize);
                attributeList = Marshal.AllocHGlobal(attributeListSize);
                if (!InitializeProcThreadAttributeList(attributeList, 1, 0, ref attributeListSize)) { throw Win32Error("InitializeProcThreadAttributeList"); }
                if (!UpdateProcThreadAttribute(attributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, pseudoConsole, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero)) { throw Win32Error("UpdateProcThreadAttribute"); }

                STARTUPINFOEX startupInfo = new STARTUPINFOEX();
                startupInfo.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
                startupInfo.lpAttributeList = attributeList;

                cast = new CastWriter(castPath, (int)width, (int)height, shellName, recordInput, castVersion);

                // Raw VT input so keystrokes (including escape sequences for TUI apps) pass through.
                if (hadConsoleMode) { SetConsoleMode(hRealIn, ENABLE_VIRTUAL_TERMINAL_INPUT); }

                PROCESS_INFORMATION processInfo;
                if (!CreateProcess(null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false, EXTENDED_STARTUPINFO_PRESENT, IntPtr.Zero, null, ref startupInfo, out processInfo))
                {
                    throw Win32Error("CreateProcess");
                }
                childProcess = processInfo.hProcess;
                childThread = processInfo.hThread;

                outputThread = new Thread(delegate() { PumpOutput(pipeOutRead, hRealOut, clock, cast); });
                inputThread = new Thread(delegate() { PumpInput(hRealIn, pipeInWrite, clock, cast, recordInput, state); });
                outputThread.IsBackground = true;
                inputThread.IsBackground = true;
                outputThread.Start();
                inputThread.Start();

                // Wait for the child while watching for stop requests and forwarding console
                // resizes to the pseudo console (recorded as 'r' events, RFC 421 capture pipeline).
                while (true)
                {
                    uint waitResult = WaitForSingleObject(childProcess, 250);
                    if (waitResult == WAIT_OBJECT_0) { break; }

                    if ((stopFilePath.Length > 0) && File.Exists(stopFilePath))
                    {
                        stoppedByRequest = true;
                        TerminateProcess(childProcess, 0);
                        WaitForSingleObject(childProcess, 5000);
                        break;
                    }

                    CONSOLE_SCREEN_BUFFER_INFO currentInfo;
                    if (GetConsoleScreenBufferInfo(hRealOut, out currentInfo))
                    {
                        short newWidth = (short)(currentInfo.srWindow.Right - currentInfo.srWindow.Left + 1);
                        short newHeight = (short)(currentInfo.srWindow.Bottom - currentInfo.srWindow.Top + 1);
                        if (((newWidth != width) || (newHeight != height)) && newWidth > 0 && newHeight > 0)
                        {
                            width = newWidth;
                            height = newHeight;
                            COORD newSize = new COORD();
                            newSize.X = width;
                            newSize.Y = height;
                            ResizePseudoConsole(pseudoConsole, newSize);
                            cast.WriteResize(clock.Elapsed.TotalSeconds, (int)width, (int)height);
                        }
                    }
                }
                state.Stop = true;

                // Closing the pseudo console flushes and closes the output pipe,
                // letting the output pump drain the remaining bytes and exit.
                ClosePseudoConsole(pseudoConsole);
                pseudoConsole = IntPtr.Zero;

                if (!outputThread.Join(3000))
                {
                    CancelIoEx(pipeOutRead, IntPtr.Zero);
                    outputThread.Join(500);
                }
                inputThread.Join(1000);

                uint exitCode = 0;
                GetExitCodeProcess(childProcess, out exitCode);

                // asciicast v3 recordings are finalized with an 'x' exit-status event.
                if ((castVersion == 3) && (cast != null))
                {
                    cast.WriteExit(clock.Elapsed.TotalSeconds, (int)exitCode);
                }

                RecordingResult result = new RecordingResult();
                result.ExitCode = (int)exitCode;
                result.DurationSec = clock.Elapsed.TotalSeconds;
                result.StoppedByRequest = stoppedByRequest;
                return result;
            }
            finally
            {
                state.Stop = true;
                clock.Stop();
                if (hadConsoleMode) { SetConsoleMode(hRealIn, savedInputMode); }
                if (cast != null) { cast.Dispose(); }
                if (childThread != IntPtr.Zero) { CloseHandle(childThread); }
                if (childProcess != IntPtr.Zero) { CloseHandle(childProcess); }
                if (attributeList != IntPtr.Zero) { DeleteProcThreadAttributeList(attributeList); Marshal.FreeHGlobal(attributeList); }
                if (pseudoConsole != IntPtr.Zero) { ClosePseudoConsole(pseudoConsole); }
                if (pipeInRead != IntPtr.Zero) { CloseHandle(pipeInRead); }
                if (pipeInWrite != IntPtr.Zero) { CloseHandle(pipeInWrite); }
                if (pipeOutRead != IntPtr.Zero) { CloseHandle(pipeOutRead); }
                if (pipeOutWrite != IntPtr.Zero) { CloseHandle(pipeOutWrite); }
            }
        }

        private static Exception Win32Error(string operation)
        {
            return new InvalidOperationException(operation + " failed with Win32 error " + Marshal.GetLastWin32Error());
        }

        private class PumpState
        {
            public volatile bool Stop;
        }

        private static void PumpOutput(IntPtr source, IntPtr destination, Stopwatch clock, CastWriter cast)
        {
            byte[] buffer = new byte[4096];
            while (true)
            {
                uint read;
                if (!ReadFile(source, buffer, (uint)buffer.Length, out read, IntPtr.Zero)) { break; }
                if (read == 0) { break; }

                byte[] chunk = new byte[read];
                Array.Copy(buffer, chunk, (int)read);

                uint written;
                WriteFile(destination, chunk, read, out written, IntPtr.Zero);
                cast.WriteEvent(clock.Elapsed.TotalSeconds, false, chunk);
            }
        }

        private static void PumpInput(IntPtr source, IntPtr destination, Stopwatch clock, CastWriter cast, bool recordInput, PumpState state)
        {
            byte[] buffer = new byte[256];
            while (!state.Stop)
            {
                uint waitResult = WaitForSingleObject(source, 100);
                if (waitResult == WAIT_TIMEOUT) { continue; }
                if (waitResult != WAIT_OBJECT_0) { break; }

                uint read;
                if (!ReadFile(source, buffer, (uint)buffer.Length, out read, IntPtr.Zero)) { break; }
                if (read == 0) { continue; }

                byte[] chunk = new byte[read];
                Array.Copy(buffer, chunk, (int)read);

                uint written;
                if (!WriteFile(destination, chunk, read, out written, IntPtr.Zero)) { break; }
                if (recordInput)
                {
                    cast.WriteEvent(clock.Elapsed.TotalSeconds, true, chunk);
                }
            }
        }
    }

    /// <summary>
    /// Writes an asciicast v2 or v3 file: a JSON header line followed by JSON event
    /// lines. v2 events carry absolute times; v3 events carry intervals since the
    /// previous event (millisecond precision) and the stream is finalized with an
    /// 'x' exit-status event. UTF-8 without BOM, LF line endings, invariant number
    /// formatting, incremental (streaming) writes.
    /// </summary>
    internal class CastWriter : IDisposable
    {
        private StreamWriter writer;
        private readonly object sync = new object();
        private int castVersion;
        private double previousElapsed;
        private Decoder outputDecoder;
        private Decoder inputDecoder;

        public CastWriter(string path, int width, int height, string shellName, bool recordedInput, int castVersion)
        {
            writer = new StreamWriter(path, false, new UTF8Encoding(false));
            writer.NewLine = "\n";
            // AutoFlush: every line (header + events) goes to disk immediately.
            // Without this, an abnormally terminated recording loses buffered
            // data - a 0-byte cast or truncated final event (issue #6).
            writer.AutoFlush = true;
            this.castVersion = castVersion;
            previousElapsed = 0.0;
            // Persistent decoders: handle multi-byte UTF-8 sequences that span
            // chunk boundaries without corrupting them to U+FFFD (issue #5).
            outputDecoder = Encoding.UTF8.GetDecoder();
            inputDecoder = Encoding.UTF8.GetDecoder();
            long timestamp = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
            string title = "Bsn.Host interactive transcript";
            if (recordedInput)
            {
                title = title + " (input captured)";
            }
            if (castVersion == 3)
            {
                // asciicast v3 header: version + term{cols,rows} are required.
                writer.WriteLine("{\"version\": 3, \"term\": {\"cols\": " + width.ToString(CultureInfo.InvariantCulture)
                    + ", \"rows\": " + height.ToString(CultureInfo.InvariantCulture)
                    + ", \"type\": \"xterm-256color\"}"
                    + ", \"timestamp\": " + timestamp.ToString(CultureInfo.InvariantCulture)
                    + ", \"command\": \"" + Escape(shellName) + "\""
                    + ", \"title\": \"" + Escape(title) + "\""
                    + ", \"env\": {\"SHELL\": \"" + Escape(shellName) + "\", \"TERM\": \"xterm-256color\"}}");
            }
            else
            {
                writer.WriteLine("{\"version\": 2, \"width\": " + width.ToString(CultureInfo.InvariantCulture)
                    + ", \"height\": " + height.ToString(CultureInfo.InvariantCulture)
                    + ", \"timestamp\": " + timestamp.ToString(CultureInfo.InvariantCulture)
                    + ", \"title\": \"" + Escape(title) + "\""
                    + ", \"env\": {\"SHELL\": \"" + Escape(shellName) + "\", \"TERM\": \"xterm-256color\"}}");
            }
        }

        private string FormatTime(double seconds)
        {
            if (castVersion == 3)
            {
                // v3: interval since the previous event, millisecond precision (spec recommendation).
                double interval = seconds - previousElapsed;
                if (interval < 0) { interval = 0; }
                previousElapsed = seconds;
                return interval.ToString("0.###", CultureInfo.InvariantCulture);
            }
            return seconds.ToString("0.######", CultureInfo.InvariantCulture);
        }

        public void WriteEvent(double seconds, bool isInput, byte[] chunk)
        {
            // Persistent decoder per stream type: multi-byte UTF-8 sequences that
            // span chunk boundaries are completed by the decoder across calls,
            // producing complete characters instead of U+FFFD replacement (issue #5).
            Decoder decoder = isInput ? inputDecoder : outputDecoder;
            char[] charBuffer = new char[chunk.Length];
            int charCount = decoder.GetChars(chunk, 0, chunk.Length, charBuffer, 0);
            string text = Escape(new string(charBuffer, 0, charCount));
            lock (sync)
            {
                if (writer == null) { return; }
                writer.WriteLine("[" + FormatTime(seconds)
                    + ", \"" + (isInput ? "i" : "o") + "\", \"" + text + "\"]");
            }
        }

        public void WriteResize(double seconds, int width, int height)
        {
            lock (sync)
            {
                if (writer == null) { return; }
                writer.WriteLine("[" + FormatTime(seconds)
                    + ", \"r\", \"" + width.ToString(CultureInfo.InvariantCulture) + "x" + height.ToString(CultureInfo.InvariantCulture) + "\"]");
            }
        }

        public void WriteExit(double seconds, int exitCode)
        {
            lock (sync)
            {
                if (writer == null) { return; }
                writer.WriteLine("[" + FormatTime(seconds)
                    + ", \"x\", \"" + exitCode.ToString(CultureInfo.InvariantCulture) + "\"]");
            }
        }

        public void Dispose()
        {
            lock (sync)
            {
                if (writer != null)
                {
                    writer.Dispose();
                    writer = null;
                }
            }
        }

        private static string Escape(string text)
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
                else if (c < 0x20 || c == 0x7f) { escaped.Append("\\u" + ((int)c).ToString("x4", CultureInfo.InvariantCulture)); }
                else { escaped.Append(c); }
            }
            return escaped.ToString();
        }
    }
}
