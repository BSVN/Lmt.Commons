# Export-BsnAuditLog

Converts an asciicast recording's audit log
([ConvertTo-BsnAuditRecord](ConvertTo-BsnAuditRecord.md) records) and
forwards it to a SIEM-style target (issue
[#21](https://github.com/BSVN/Lmt.Commons/issues/21)): local NDJSON,
syslog (RFC 5424), Splunk HEC, or the readable audit transcript.

## Usage

```powershell
Export-BsnAuditLog -Path session01.cast -Target NDJSON   -OutPath session01.ndjson
Export-BsnAuditLog -Path session01.cast -Target Syslog   -Server log.example -Port 6514 -Transport TLS -Facility Local0
Export-BsnAuditLog -Path session01.cast -Target SplunkHec -Uri https://splunk.example:8088 -Index audit -Sourcetype 'bsn:audit:session'
Export-BsnAuditLog -Path session01.cast -Target Transcript -OutPath audit01.txt
```

Supports `-WhatIf`/`-Confirm` (an audit export that silently drops
events is worse than a loud one; forwarder failures are terminating
errors).

## Targets

### NDJSON

One canonical JSON record per line, UTF-8 without BOM, LF line endings -
the local sink every SIEM ingests.

### Syslog (RFC 5424)

```
<134>1 2026-11-08T14:23:01.123456Z ws01 bsn.host bsn-1a2b3c4d5e6f BSN_SESSION_INPUT [bsn@32473 session_id="bsn-..." cast_sha256="9f86d0..." offset_ms="8123"] {"schema":"bsn.audit/1",...}
```

- PRI = facility * 8 + severity (severity mapping: open/close + markers
  = notice, input/output = info, resize = debug); facility defaults to
  `Local0` (16), configurable `Local0`-`Local7`.
- APP-NAME `bsn.host`, PROCID = session id, MSGID = `BSN_<EVENTTYPE>`.
- Structured data carries the correlation keys; the SD-ID `bsn@32473` is
  a **placeholder** - register a free IANA Private Enterprise Number and
  pass your own via `-StructuredDataId`.
- MSG = compact canonical JSON; control bytes are JSON-escaped.
- TCP/TLS frames use RFC 6587 octet-counting framing; UDP sends one
  datagram per record. **TLS is the default** - plain TCP and UDP are
  explicit opt-ins for lab environments.

### Splunk HEC

```json
{"time":1762609381.123,"host":"ws01","event":{...},"source":"bsn.host",
 "sourcetype":"bsn:audit","index":"audit",
 "fields":{"session_id":"bsn-...","event_type":"session_input",
           "severity":"info","cast_sha256":"9f86d0..."}}
```

- Batched (`-BatchSize`, default 50 events per request) to
  `/services/collector/event`; **HTTPS only** - the token never travels
  over plain HTTP and is never logged.
- Token from `-Token` or the `BSN_SPLUNK_HEC_TOKEN` environment
  variable; the export fails when neither is set.
- `-Ack` verifies indexed-event delivery via the HEC acknowledgment
  endpoint (requires ack configured on the Splunk side).
- Dotted lowercase sourcetypes (e.g. `bsn:audit:session`) are the Splunk
  best practice; `fields` carries the high-cardinality indexed fields.

### Transcript

The Start-Transcript-style readable rendering with the Bsn audit frame
(`ConvertTo-BsnTranscript -HeaderMode Bsn` semantics) - the
human-readable deliverable auditors open directly.

## Evidence chain

```powershell
Export-BsnAuditLog -Path session01.cast -Target Transcript -OutPath audit01.txt
Export-BsnAuditLog -Path session01.cast -Target NDJSON -OutPath audit01.ndjson -TranscriptPath audit01.txt
```

With `-TranscriptPath`, every record's evidence block carries
`transcript_sha256` next to `cast_sha256`: a SIEM hit then resolves to
the machine-readable record, the bit-exact cast (replayable with
`Show-InteractiveTranscript`) and the human-readable txt.

## Privacy

- Input records are opt-in (`-IncludeInput`) - input contains everything
  typed, including secrets.
- Masking heuristic on by default (`password=***` style); `-NoMaskSecrets`
  disables it. **Never a guarantee** - secrets typed at hidden prompts are
  undetectable.
- Output records are opt-in (`-IncludeOutput`), ANSI-stripped and
  size-capped (`-OutputSizeCap`, default 512).
- Full-fidelity content stays in the cast (the evidence); the log
  carries only capped, sanitized extracts.

## See also

- [ConvertTo-BsnAuditRecord](ConvertTo-BsnAuditRecord.md) - the pure
  record converter
- [ConvertTo-BsnTranscript](ConvertTo-BsnTranscript.md) - the transcript
  target's rendering
- [Start-InteractiveTranscript](Start-InteractiveTranscript.md)
