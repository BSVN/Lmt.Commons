# System Tests for Bsn.Host

End-to-end tests that exercise the full public API of
`Start-InteractiveTranscript`, `Stop-InteractiveTranscript`, and
`Show-InteractiveTranscript` — no mocks, real pseudo-terminals, real
recordings.

## Architecture

```
                    ┌─────────────────────────────────────────┐
                    │           Scenario Script               │
                    │  (pwsh -NoProfile -File scenario.ps1)   │
                    │                                         │
                    │  SYSMARK-A: recorded session start     │
                    │  SYSMARK-PID: <pid>                    │
                    │  [TUI: alt-screen, clear, draw, exit]  │
                    │  SYSMARK-B: after TUI exit             │
                    └───────────────┬─────────────────────────┘
                                    │
                    ┌───────────────┼───────────────┐
                    │               │               │
                    ▼               ▼               ▼
          ┌─────────────┐  ┌──────────────┐  ┌────────────────┐
          │   Ground    │  │  Our Tool    │  │  Independent   │
          │   Truth     │  │              │  │  Tools         │
          │             │  │  Start-      │  │                │
          │  pwsh >     │  │  Interactive │  │  asciinema rec │
          │  truth.txt  │  │  Transcript  │  │  (Linux)       │
          │             │  │  → .cast    │  │                │
          │  No tool,   │  │              │  │  tmux pipe-pane│
          │  just pipe  │  │              │  │  (Linux)       │
          │  output     │  │              │  │                │
          │             │  │              │  │  conlog.exe    │
          │             │  │              │  │  (Windows)     │
          └──────┬──────┘  └──────┬──────┘  └───────┬────────┘
                 │                │                 │
                 ▼                ▼                 ▼
          ┌─────────────────────────────────────────────┐
          │          Compare (VT-stripped plain text)   │
          │                                             │
          │  Every marker in ground truth must appear   │
          │  in the cast AND in the independent tool's  │
          │  output. Order must be preserved.           │
          └─────────────────────────────────────────────┘
```

## The Scenario

All tests record the same scenario: a PowerShell script that exercises
both simple cmdlet output AND a simulated TUI application.

```
SYSMARK-A: recorded session start        ← plain output (cmdlet)
SYSMARK-PID: 12345                       ← real cmdlet output (varies per run)
ESC[?1049h                              ← TUI enters alternate screen
ESC[2J ESC[H                            ← TUI clears screen, homes cursor
TUI-FRAME: simulated full-screen app    ← TUI draws content
  (short sleep or 120s sleep)            ← depending on test
ESC[?1049l                              ← TUI exits alternate screen
SYSMARK-B: after TUI exit               ← plain output
```

The alternate-screen sequences (`ESC[?1049h` / `ESC[?1049l`) are exactly
what real ncurses-style applications (vim, htop, nmtui, sconfig) emit.

## Test Contexts

### 1. Truth-table: ground truth vs our recording

**What it validates**: The cast captures everything the terminal would
show — no more, no less.

| Step | Action |
|------|--------|
| 1 | Run scenario unrecorded: `pwsh -File scenario.ps1 > truth.txt` |
| 2 | Run scenario recorded: `Start-InteractiveTranscript` → `.cast` |
| 3 | VT-strip both to plain text |
| 4 | **Marker check**: every marker in truth appears in cast |
| 5 | **Line check**: every normalized line in truth appears in cast |
| 6 | **Order check**: markers in same relative sequence |

### 2. Session recording (known-answer test)

**What it validates**: The recording is well-formed and complete.

| Step | Action |
|------|--------|
| 1 | Record the full scenario via `Start-InteractiveTranscript` |
| 2 | Verify: ExitCode=0, StoppedByRequest=false |
| 3 | Verify: cast header (version 2/3, cols/rows > 0) |
| 4 | Verify: alt-screen sequences in raw stream |
| 5 | Verify: markers in correct order in plain text |
| 6 | Verify: no `i` (keystroke) events |

### 3. Stop-channel finalization

**What it validates**: `Stop-InteractiveTranscript` works from inside the
recorded session.

| Step | Action |
|------|--------|
| 1 | Record a 120-second scenario (long sleep) |
| 2 | Thread job creates the stop file after 6 seconds |
| 3 | Verify: StoppedByRequest=true |
| 4 | Verify: DurationSec < 60 (stopped early, not at 120s) |
| 5 | Verify: pre-stop markers present in cast |
| 6 | Verify: post-sleep marker absent from cast |

### 4. Cross-check: asciinema (Linux)

**What it validates**: Our recording agrees with the reference
implementation of the asciicast format.

| Step | Action |
|------|--------|
| 1 | Record with `asciinema rec -q -c "pwsh -File scenario.ps1"` → `.cast` |
| 2 | Record with `Start-InteractiveTranscript` → `.cast` |
| 3 | Parse both casts (both are asciicast v2) |
| 4 | Verify: same markers in both outputs |
| 5 | Verify: both contain alt-screen sequences |

**Why asciinema**: It is the reference implementation of the asciicast
format. If our cast and an asciinema recording of the same session agree,
our format and capture are correct.

**Requires**: `pip install asciinema` (Linux). Skips if not installed.

### 5. Cross-check: tmux pipe-pane (Linux)

**What it validates**: Our recording agrees with tmux's independent PTY
mechanism — a completely different terminal multiplexer infrastructure.

| Step | Action |
|------|--------|
| 1 | Run scenario in detached tmux session, pipe pane output to file |
| 2 | Record with `Start-InteractiveTranscript` |
| 3 | VT-strip both |
| 4 | Verify: same markers in both |

**Why tmux**: tmux uses its own PTY allocation, completely independent
from both `script(1)` and ConPTY. If all three mechanisms agree, the
capture is proven across different PTY implementations.

**Requires**: tmux (pre-installed on ubuntu runners). Skips if not
available or if in a non-interactive CI session.

### 6. Cross-check: console-logger (Windows)

**What it validates**: Our ConPTY wrapper agrees with an independent
third-party ConPTY implementation.

| Step | Action |
|------|--------|
| 1 | Run `conlog.exe pwsh -File scenario.ps1 > conlog.txt` |
| 2 | Record with `Start-InteractiveTranscript` |
| 3 | VT-strip both |
| 4 | Verify: same markers in both |
| 5 | Verify: both contain alt-screen sequences |

**Why console-logger**: Cited in RFC 421 as proof that ConPTY recording
works on Windows. It's an independent implementation by a different
author — if both wrappers agree, our ConPTY handling is correct.

**Requires**: `conlog.exe` on PATH (build from
[github.com/rhubarb-geek-nz/console-logger](https://github.com/rhubarb-geek-nz/console-logger)).
CI builds it from source; skips gracefully if unavailable.

## Platform Support Matrix

| Test | Windows CI | Windows local | Linux CI | Linux local | macOS CI | macOS local |
|------|-----------|---------------|----------|-------------|----------|-------------|
| Truth-table (ground truth) | ✅ | ✅ | ⏭️* | ✅ | ⏭️* | ✅ |
| Session recording | ✅ | ✅ | ⏭️* | ✅ | ⏭️* | ✅ |
| Stop finalization | ✅ | ✅ | ⏭️* | ✅ | ⏭️* | ✅ |
| asciinema cross-check | N/A | N/A | ⏭️† | ✅ | ⏭️† | ✅ |
| tmux cross-check | N/A | N/A | ⏭️† | ✅ | ⏭️† | ⏭️‡ |
| console-logger cross-check | ✅ | ✅ | N/A | N/A | N/A | N/A |

\* Linux system tests skip in CI (GitHub Actions) because the Unix
`script(1)` engine's `ProcessStartInfo.Arguments` construction is
unreliable under redirected stdio. Run locally in a real terminal.

† CI runners have redirected stdio, which prevents interactive terminal
tools (asciinema, tmux) from working.

‡ tmux is not pre-installed on macOS runners.

## How Windows recording works in CI

GitHub Actions Windows runners have redirected stdio, which causes
Windows to route child process output around the ConPTY (verified
empirically). The workaround: the test spawns a child `pwsh` process
with its own (hidden) console via `Start-Process -WindowStyle Hidden`.
That process gets a real console, so the ConPTY proxy works correctly.

```
Pester test process (redirected stdio)
  └── Start-Process pwsh -WindowStyle Hidden (real console)
        └── Start-InteractiveTranscript
              └── ConPTY → cmd.exe → pwsh scenario.ps1
                    └── Output: cast file + result JSON
```

## Files

| File | Purpose |
|------|---------|
| `InteractiveTranscript.System.Tests.ps1` | All system tests |
| `scenario.ps1` (generated) | The recorded script (markers + TUI simulation) |
| `runner.ps1` (generated) | Windows hidden-console recording runner |
