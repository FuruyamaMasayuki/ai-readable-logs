## 0.4.0

### Added

- **`JsonlPrintSink`.** Prints the same wire format `JsonlFileSink` writes,
  one line per event, through `print`. Exists for a real device with no
  reachable filesystem path: `flutter run` already mirrors the app's print
  output into your terminal live, so piping that session through `tee` and
  extracting the JSON lines gets you a file `ailog_digest` can read, with no
  `adb pull` or Xcode device menu involved. Composes safely with
  `capturePrints` — no re-logging loop — verified by test.
- **Build-mode control.** `isDebugBuild` / `isProfileBuild` /
  `isReleaseBuild` / `currentBuildMode` are `const`, read from the
  compiler-defined `dart.vm.product` and `dart.vm.profile` — the same values
  Flutter's `kReleaseMode` is built on, with no Flutter dependency.
  `byBuildMode(debug:, profile:, release:)` picks any value per mode.
  `Logger.create(enabled: false)` and `Logger.disabled()` switch logging off:
  measured at 5 ns per call in a release AOT build, ahead of all formatting,
  sanitizing and breadcrumb work. Because the constants fold at compile time,
  `isReleaseBuild ? Logger.disabled() : Logger.create(sink: ...)` lets the
  AOT compiler drop the sink entirely — verified by compiling and confirming
  the dead branch's strings are absent from the binary.
- `ConsoleSink.usingPrint()` / `ConsoleSink(write: ...)`.
- `benchmark/logging_benchmark.dart`, so the README's performance numbers can
  be re-run rather than believed.

### Fixed

- **A script that only called `flush()` never exited.** `JsonlFileSink`'s
  default `flushInterval` schedules a periodic `Timer`, and only `close()`
  cancels it — a live `Timer` keeps the isolate alive, so `main()` returning
  after `flush()` alone left the process hanging until killed. Found by
  running the README's own quick-start example verbatim. The class doc, the
  Quick Start in both READMEs, and every example now call `close()`, and a
  subprocess regression test (`test/regression/`) guards it going forward.

- **`includePlatformContext` duplicated ~133 bytes on every line** — OS,
  Dart version, pid and locale, identical each time, in a format whose whole
  premise is not wasting a context window. Measured: a 100-event file grew
  73%, 182 → 315 bytes per line. `JsonlFileSink` now writes the platform
  into each file's `_hdr` record once, and the option's documentation states
  the per-event cost.

- **`JsonlFileSink` could silently lose events.** Repeated `IOSink.flush()`
  on a handle from `File.openWrite()`, with writes arriving between flushes,
  dropped data — measured at 9 of 15 events lost in an ordinary
  request-handler-shaped loop. The sink was rewritten onto a synchronous
  `RandomAccessFile` with an explicit buffer; durability no longer depends
  on the event loop getting a turn. New: `isHealthy`, `droppedEvents`,
  `onError`, `bufferBytes`, `flushOnErrorLevel`.
- `package:ailog` frames are now classified as noise, not application
  frames — previously a digest's five-frame budget could be spent entirely
  on this package's own zone plumbing, and the fingerprint could group
  unrelated bugs logged through the same helper.
- Digest timestamps rendered in local time while the JSONL is UTC.

### Added

- **Whole-log aggregates in the digest.** Every message shape counted
  (`lease acquired ×40` vs `lease released ×9`), and min/max/last of every
  numeric context field. Driven by a blind A/B test: a summarized digest
  lost to the raw log on a connection-pool leak because the evidence — the
  releases that never happened — lived in the *successful* requests, which
  summarization had discarded. With the counts added, the digest found the
  same root cause from a fifth of the bytes.
- **`LogFilter` / `LogSelection`:** choose what is worth an AI's context
  window — `collapseRepeats`, `aroundErrors`, `onlyFailedTraces`,
  level/logger/time/count bounds. Aggregates are computed over the
  *unfiltered* input, and both output formats state what was dropped.
- **String output.** `MemorySink.toJsonl()`/`toMarkdown()`/`export()`,
  `LogSelection.toReport()` (digest + surviving events),
  `buildDigest(events)`, `digestFromJsonl(text)`. No filesystem — works on
  web.
- **`capturePrints`:** route ordinary `print()` calls into the structured
  log (tagged `print`, ambient trace attached), with a re-entrancy guard so
  a console sink cannot feed back into the log.
- **`ConsoleSink.usingPrint()`** and `ConsoleSink(write: ...)`. The sink
  wrote to `stdout` unconditionally, which on a Flutter device reaches
  neither logcat nor the unified log — console output there was simply
  invisible. A custom writer can also no longer break the caller by
  throwing.
- Digest honesty: breadcrumb entries are labeled as breadcrumbs, loggers
  that appear only inside causal chains are called out, and a group's
  context sample is labeled `first of N` (with the most recent shown when
  it differs).

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
