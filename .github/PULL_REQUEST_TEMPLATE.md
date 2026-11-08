<!--
  Thank you for contributing to the Bsn.* module family!

  Notes for reviewers and authors:
  - Keep the PR title short and imperative, e.g. "Fix console codepage restore in cast playback".
  - PRs must never change ModuleVersion in any .psd1, add release dates to CHANGELOG.md,
    or rename the `## [Unreleased]` section - versioning happens only in the release step.
  - CI runs Analyze + Test on windows/ubuntu/macos; all three must pass before merge.
-->

## Summary

<!-- One or two sentences: what does this PR do? -->

## Motivation and Context

<!-- Why is this change needed? Link related issues with Fixes #<issue>, or state the problem. -->

## Changes

<!-- Bullet list of the notable changes (code, docs, tests, build). -->

-
-

## How Has This Been Tested?

<!-- Describe how you verified the change (local run, tests, platforms). -->

- [ ] `./build.ps1 -Task Analyze, Test` passes locally
- [ ] Verified on Windows PowerShell 5.1 **and** PowerShell 7 (when the change can differ between editions)
- [ ] Verified cross-platform (windows / ubuntu / macos) or the change is Windows-only and gated

## Checklist

- [ ] CHANGELOG.md: changes folded into the existing `## [Unreleased]` section (no new version sections, no dates)
- [ ] No `ModuleVersion` change in any `.psd1`
- [ ] Tests added or updated under `src/<Module>/tests/*.Tests.ps1`; no test suspends, sleeps, or reboots a real machine
- [ ] New/changed public cmdlets ship all three doc artifacts: comment-based help, `en-US/about_*.help.txt`, and `docs/en-US/<Cmdlet>.md`
- [ ] New private helpers follow `<ApprovedVerb>-Bsn<Noun>` naming
- [ ] `.ps1` / `.psm1` files are ASCII-only
- [ ] C# changes (if any): warning-free for netstandard2.0; new testable logic is unit-tested in `src/Bsn.Host/tests/csharp`, ConPTY/P-Invoke code excluded from coverage stays excluded in `codecov.yml`
