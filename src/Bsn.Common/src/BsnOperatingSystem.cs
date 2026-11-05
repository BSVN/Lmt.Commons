namespace Bsn.Common
{
    /// <summary>
    /// The operating system PowerShell is running on, as detected by
    /// Get-BsnOperatingSystem in the Bsn.Common PowerShell module.
    /// </summary>
    public enum BsnOperatingSystem
    {
        /// <summary>Windows (ConPTY-capable hosts).</summary>
        Windows,

        /// <summary>Linux distributions.</summary>
        Linux,

        /// <summary>macOS.</summary>
        macOS,

        /// <summary>The platform could not be determined.</summary>
        Unknown
    }
}
