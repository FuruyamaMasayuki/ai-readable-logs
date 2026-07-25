## 0.3.0

### Fixed

- **The digest over-counted errors, corrupting its own ranking.** Idiomatic
  usage logs one failure more than once as it propagates — `span()` records
  the failure passing through it, then the caller catches the same exception
  at a boundary and logs it again. Both are correct; together they doubled
  the reported frequency, and could rank a deep-stack error above a
  shallower but genuinely more widespread one. Verified on a realistic
  session: two failed requests were reported as `×4`.

  `ErrorGroup` now tracks `incidents` (distinct traces) alongside
  `occurrences` (raw log events), ranks by the former, and reports both when
  they diverge. Untraced events count individually, since they can't be
  attributed to a request.

### Changed

- `ErrorGroup.count` renamed to `ErrorGroup.occurrences`; `incidents` added.
  The digest's JSON output gains `incidents` and renames `count` to
  `occurrences`.
- The digest picks the richest available causal chain for a group rather
  than the chronologically last one — the last event is often the outermost
  re-log, which carries less context than the innermost.
- Retained sample trace IDs per error group are bounded (32); the incident
  count stays exact past that bound.

## 0.2.0

### Added

- **Checkpoints.** `logger.checkpoint()` — or any leveled method with a null
  message — records *where* it was called
  (`→ checkout.dart:42 CartService.charge`) and tags the event `checkpoint`.
  Proves a code path ran without inventing throwaway messages, and stays
  correct when the code moves. Defaults to `trace`, and the stack is only
  captured after the level filter passes, so it costs nothing in production.
- `CallSite` / `captureCallSite` exported for custom use.
- `Sanitizer.sanitizeText` for redacting and length-bounding a standalone
  string.

### Fixed

- **Over-redaction of ordinary fields.** `defaultSensitiveKeyPattern` matched
  as a bare substring, so `pin` hit `shippingAddress`/`opinionText`/
  `spinnerValue` and `auth` hit `bookAuthor`/`coAuthorEmail` — those fields
  had their values silently destroyed. Key names are now split into words
  (camelCase / `_` / `-` / `.`) and matched per word. Plurals
  (`credentials`, `secrets`) now match too.
- **Unbounded `msg` and `err.m` / `err.fr`.** These bypassed
  `SanitizerLimits.maxStringLength` entirely, so one
  `logger.info(hugeString)` could put megabytes on a single line — exactly
  the context-window blowout the size limits exist to prevent. All three now
  go through the same bound as context values.
- **Truncation could split a redaction placeholder**, leaving
  `[redacted:ema` — which reads like leaked data rather than a mask.
  Truncation now pulls back to before the placeholder.
- **`JsonlFileSink.add` could throw**, violating `LogSink`'s documented
  "must never throw" contract. `_rotate`'s reopen was unguarded, so a full
  disk or a deleted log directory propagated into the caller — right when a
  crash was being logged. It now degrades to dropping events.

### Changed

- Leveled methods (`trace`/`debug`/`info`/`warn`/`errorMessage`) take
  `String?` instead of `String`, to support the checkpoint form. Existing
  calls are unaffected.
- `schemaLegend()` no longer claims `seq` is comparable across writers — it
  is monotonic within one `ses` only, which matters when native crash-time
  writes and Dart writes share a file.
- `CausalBuffer` documents honestly that untraced events share one bucket,
  so a chain on an untraced error may include unrelated events.

## 0.1.1

- Added `Logger.logError` to emit a pre-built `ErrorInfo` for errors that
  didn't originate as a Dart exception (e.g. forwarded from native
  iOS/Android code by `ailog_flutter`'s native bridge).
- Added `errorFingerprintFromFrames` to fingerprint an error from plain
  frame strings, skipping Dart-specific `StackTrace` parsing.
- Fixed an off-by-one in `JsonlFileSink` rotation: `maxFiles` now keeps
  exactly that many rotated files (`app.jsonl.1` … `app.jsonl.N`) instead
  of one fewer.
- Exported `DigestBuilder`/`Digest`/`ErrorGroup` and `SequenceCounter` from
  the main `ailog.dart` library (previously importable only from `src/`).

## 0.1.0

- Initial release: JSONL structured logging, trace/span correlation via
  `Zone`, automatic causal chain attachment on errors, error fingerprinting
  and grouping, automatic secret redaction with correlation tokens,
  bounded/sanitized context values, and the `ailog_digest` CLI.
