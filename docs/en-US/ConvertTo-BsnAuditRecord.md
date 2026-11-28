# ConvertTo-BsnAuditRecord

Converts an asciicast (`.cast`) recording into canonical audit records -
the machine-readable index of the recorded evidence (issue
[#21](https://github.com/BSVN/Lmt.Commons/issues/21)).

One recording, several consumers - deliberate layering, no parallel
parsers:

| Artifact | Consumer |
|---|---|
| `.cast` file | bit-exact evidence, replayable |
| `Show-InteractiveTranscript` player | humans, interactive replay |
| Start-Transcript-style `.txt` (`ConvertTo-BsnTranscript`) | humans / auditors |
| Canonical audit records (**this cmdlet**) | machines / SIEM - index and alerting |

Design principle: **the log is the index, the cast is the evidence.**
Every record carries `cast_sha256` + `event_index` + `offset_ms`, so any
SIEM hit can be replayed bit-exact from the cast.

## Usage

```powershell
ConvertTo-BsnAuditRecord session01.cast                              # open, resize, marker, close, summary
ConvertTo-BsnAuditRecord session01.cast -IncludeInput                # + masked typed-input records
ConvertTo-BsnAuditRecord session01.cast -IncludeOutput               # + capped, ANSI-stripped output records
ConvertTo-BsnAuditRecord session01.cast | ConvertTo-Json             # pipe-friendly
```

The conversion is pure: it reuses the shared `Get-BsnCastTimeline`
parser (no console replay, no network) and emits JSON-serializable
`PSCustomObject` records with stable property order.

## Canonical record (schema `bsn.audit/1`)

```json
{
  "schema": "bsn.audit/1",
  "time": "2026-11-08T14:23:01.123456Z",
  "event": { "kind": "session_activity", "type": "session_input", "outcome": "success" },
  "severity": "info",
  "session": { "id": "bsn-1a2b3c4d5e6f", "recorded_by": "bsn.host 0.3.0",
               "host": "ws01", "user": "jdoe", "shell": "pwsh",
               "command": "pwsh -NoProfile", "origin": "local" },
  "position": { "offset_ms": 8123, "event_index": 412, "stream": "input" },
  "input": { "text": "ls -la\r", "masked": true },
  "evidence": { "cast_path": "audit/session01.cast", "cast_sha256": "9f86d0...",
                "cast_bytes": 1048576, "transcript_sha256": null }
}
```

- **time** - RFC 3339 UTC with fractional seconds: cast header timestamp
  plus the event's relative offset (casts store relative times only).
- **severity** - notice (`session_open`/`session_close`/`session_marker`
  /`session_summary`), info (input/output), debug (resize); mapped to
  RFC 5424 PRI values by the syslog exporter.
- **session** - `shell` and `command` come from the cast header; `host`
  and `user` are blank for ecosystem casts unless supplied via
  `-ComputerName`/`-UserName` - recordings made by
  Start-InteractiveTranscript carry them in the header's capture-time
  `bsn` metadata block, which fills the session context automatically
  (along with `id` from the recorded GUID session id and
  `recorded_by` from the recording module version). Explicit parameters
  still override the block.
- **input** - opt-in (`-IncludeInput`); masked by the heuristic
  (`password=***`) by default, `-NoMaskSecrets` disables it. The
  heuristic is never a guarantee - secrets typed at hidden prompts are
  undetectable.
- **output** - opt-in (`-IncludeOutput`); ANSI-stripped,
  carriage-return-overtype-resolved, capped by `-OutputSizeCap`
  (default 512) and flagged when truncated.
- **evidence** - `transcript_sha256` is embedded when `-TranscriptPath`
  points at the readable rendering of the same cast, tying the SIEM hit
  to the machine-readable record, the bit-exact replay and the
  human-readable txt.

## Event taxonomy

| `event.type` | Source in cast | Severity |
|---|---|---|
| `session_open` | header | notice |
| `session_input` | `i` events (`-IncludeInput`) | info |
| `session_output` | `o` events (`-IncludeOutput`) | info |
| `session_resize` | `r` events | debug |
| `session_marker` | `m` events | notice |
| `session_close` | end of timeline | notice |
| `session_summary` | derived counts - always emitted | notice |

## See also

- [Export-BsnAuditLog](Export-BsnAuditLog.md) - NDJSON / syslog (RFC
  5424) / Splunk HEC / transcript targets
- [ConvertTo-BsnTranscript](ConvertTo-BsnTranscript.md) - the readable
  rendering of the same evidence
- [Start-InteractiveTranscript](Start-InteractiveTranscript.md)
