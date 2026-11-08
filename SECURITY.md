# Security Policy

## Supported versions

Each `Bsn.*` module is versioned independently. Security fixes are made
against the current development state and shipped in the **latest release**
of each module; only the most recent published version of each module is
supported. Check the module table in the [README](README.md) or the
[releases page](https://github.com/BSVN/Lmt.Commons/releases) and
[CHANGELOG.md](CHANGELOG.md) for current versions.

## Reporting a vulnerability

**Please do not report security vulnerabilities through public GitHub
issues, discussions, or pull requests.**

Use GitHub's private vulnerability reporting on this repository:

1. Go to the **Security** tab of [BSVN/Lmt.Commons](https://github.com/BSVN/Lmt.Commons/security).
2. Click **Report a vulnerability**.
3. Describe the issue and fill in as much of the following as you can.

If private vulnerability reporting is unavailable for any reason, email
soorosh_abi@hotmail.com with `[security]` in the subject line.

### What to include

- Affected module(s) and version(s), e.g. `Bsn.Host 0.2.4` from the manifest
- PowerShell edition and version (`$PSVersionTable`) and OS
- Step-by-step reproduction or proof of concept
- Impact assessment (what an attacker could gain)

## Scope

In scope:

- The PowerShell modules and their published packages on the
  [PowerShell Gallery](https://www.powershellgallery.com/) and the
  [GitHub Packages mirror](https://github.com/orgs/BSVN/packages) (e.g.
  package integrity, code execution via cmdlet parameters or transcript
  processing)
- The CI/publish pipeline as it affects package integrity (e.g. evidence
  that a release artifact was not produced from the tagged source)

Out of scope:

- Vulnerabilities in third-party dependencies that are already tracked
  upstream (still welcome as an issue if they affect this repo)
- Social engineering of GitHub, Microsoft, or PowerShell Gallery support
- Reports from automated scanners without a working proof of concept

## What to expect

- Acknowledgement within approximately 5 business days.
- We will investigate, keep you informed, and coordinate disclosure timing
  with you. Fixes ship in the next release of the affected module(s).
- Credit in the changelog and release notes if you wish.

This is a client-side PowerShell tool suite with no server components;
please only test against machines and accounts you own or have permission
to use.
