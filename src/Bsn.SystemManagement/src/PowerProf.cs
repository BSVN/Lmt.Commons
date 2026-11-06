using System.Runtime.InteropServices;

namespace Bsn.SystemManagement.Interop
{
    /// <summary>
    /// P/Invoke wrapper for the documented Windows power management APIs.
    /// </summary>
    public static class PowerProf
    {
        /// <summary>
        /// Suspends (sleeps or hibernates) the system. See
        /// https://learn.microsoft.com/en-us/windows/win32/api/powrprof/nf-powrprof-setsuspendstate
        /// </summary>
        /// <param name="hibernate">true to hibernate (S4) instead of suspend (S3 / Modern Standby).</param>
        /// <param name="forceCritical">true to force a critical suspension without waiting for applications.</param>
        /// <param name="disableWakeEvent">true to disable wake events.</param>
        /// <returns>Nonzero on success; zero on failure (call Marshal.GetLastWin32Error).</returns>
        [DllImport("powrprof.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent);
    }
}
