<#
.SYNOPSIS
    Records a command inside a Windows pseudo-console (ConPTY) to a cast file.

.DESCRIPTION
    Compiles a self-contained C# ConPTY engine (modelled on the EchoCon
    pattern) that:
    - creates a pseudo-console with two pipes,
    - starts the command line attached to it,
    - proxies raw console input into the pseudo-console,
    - tees the pseudo-console's VT output to the real console and, with
      timestamps, into an asciicast v2 file,
    - restores the console input mode when the recorded process exits.

    The engine requires Windows 10 1809+ (CreatePseudoConsole).
#>
function Start-BsnWindowsPtyRecording {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Confirmation is owned by the public Start-InteractiveTranscript cmdlet.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandLine,

        [Parameter(Mandatory = $true)]
        [string]$CastPath,

        [switch]$RecordInput
    )

    if (-not ('Bsn.Host.Interop.PtyRecorder' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Bsn.Host.Interop
{
    public class RecordingResult
    {
        public int ExitCode { get; set; }
        public double DurationSec { get; set; }
    }

    public static class PtyRecorder
    {
        private const int STD_INPUT_HANDLE = -10;
        private const int STD_OUTPUT_HANDLE = -11;
        private const uint ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200;
        private const uint WAIT_OBJECT_0 = 0;
        private const uint WAIT_TIMEOUT = 258;
        private static readonly IntPtr PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = (IntPtr)0x00020016;
        private const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
        private const uint INFINITE = 0xFFFFFFFF;

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
        private static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeleteProcThreadAttributeList(IntPtr lpAttributeList);

        public static RecordingResult Run(string commandLine, string castPath, bool recordInput)
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

                cast = new CastWriter(castPath, (int)width, (int)height);

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

                WaitForSingleObject(childProcess, INFINITE);
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

                uint exitCode;
                GetExitCodeProcess(childProcess, out exitCode);

                RecordingResult result = new RecordingResult();
                result.ExitCode = (int)exitCode;
                result.DurationSec = clock.Elapsed.TotalSeconds;
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

    internal class CastWriter : IDisposable
    {
        private StreamWriter writer;

        public CastWriter(string path, int width, int height)
        {
            writer = new StreamWriter(path, false, new UTF8Encoding(false));
            writer.NewLine = "\n";
            long timestamp = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
            writer.WriteLine("{\"version\": 2, \"width\": " + width.ToString(CultureInfo.InvariantCulture)
                + ", \"height\": " + height.ToString(CultureInfo.InvariantCulture)
                + ", \"timestamp\": " + timestamp.ToString(CultureInfo.InvariantCulture)
                + ", \"env\": {\"TERM\": \"xterm-256color\"}}");
        }

        public void WriteEvent(double seconds, bool isInput, byte[] chunk)
        {
            string text = Escape(Encoding.UTF8.GetString(chunk));
            writer.WriteLine("[" + seconds.ToString("0.######", CultureInfo.InvariantCulture)
                + ", \"" + (isInput ? "i" : "o") + "\", \"" + text + "\"]");
        }

        public void Dispose()
        {
            if (writer != null)
            {
                writer.Dispose();
                writer = null;
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
'@
    }

    $exitCode = 0
    $durationSec = 0.0
    $completed = $false
    try {
        $engineResult = [Bsn.Host.Interop.PtyRecorder]::Run($CommandLine, $CastPath, $RecordInput.IsPresent)
        $exitCode = $engineResult.ExitCode
        $durationSec = $engineResult.DurationSec
        $completed = $true
    }
    catch [System.Runtime.InteropServices.EntryPointNotFoundException] {
        throw 'Interactive transcripts on Windows require pseudo-console support (Windows 10 1809 or newer).'
    }

    return [pscustomobject]@{
        ExitCode    = $exitCode
        DurationSec = $durationSec
        Completed   = $completed
    }
}
