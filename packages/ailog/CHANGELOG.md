# Changelog

This package is **pre-1.0 and under active development**. Following
[semver](https://dart.dev/tools/pub/versioning) for `0.x`, a **minor bump
may break you** — the entries below marked "Changed" are the ones that do.
Pin an exact version and read this file before upgrading. The API will not
be considered stable until `1.0.0`.

## 0.4.0

### Changed

- **A release build now logs nothing unless you ask it to.** `enabled` on
  `Logger.create` defaults to `!isReleaseBuild` instead of `true`, so
  `flutter build` / `dart compile exe` ship silent by default and only a
  debug or profile build logs out of the box. Opt back in with
  `Logger.create(sink: ..., enabled: true)` — a plain argument, so it works
  the same in every mode — or with a runtime flag (`enabled: userOptedIn`)
  for a diagnostics toggle in settings. `Logger.forTesting()` passes
  `enabled: true` itself, so a test compiled AOT still logs.

  The tradeoff is real and worth stating: the failures most worth analyzing
  are the ones users hit in production, and a silent release cannot describe
  them. The default is chosen for the case where nobody has decided yet —
  writing to a user's device and printing to their console are both things
  to opt into, not out of. When you *can* retrieve the log,
  `enabled: true` with `minimumLevel: byBuildMode(debug: LogLevel.trace,
  release: LogLevel.info)` is the better configuration.

  Verified against a real `dart compile exe` binary: default `events=0`,
  `enabled: true` `events=2`, `forTesting()` `events=2`; the same four cases
  under JIT give 2 / 2 / 2 with only `enabled: false` at 0.
- `Span` has no `end()` — the README documented one that never existed. The
  real methods are `succeed()` and `fail()`. `tool/documented_api_check.dart`
  now references every documented API and is analyzed in CI, so an example
  that drifts from the code fails the build.
- `fnv1a64` (returning `int`) is replaced by **`fnv1a64Hex`** (returning the
  16-character hex string). A 64-bit value cannot be represented in a web
  `int`, so no `int`-returning form can be correct everywhere this package
  runs. `shortHash` also drops its unused `seed` parameter, whose default
  was itself a web-breaking literal.

### Added

- **`installDebugSync` + `ailog_sync`: the log syncs itself while you debug.**
  Every other way to get a file off a device is something you do — `adb
  pull`, Xcode's container download, a share button, a `tee` pipeline with a
  `grep` after it. This is a call at startup and a command on your machine,
  after which a local `.jsonl` grows as you use the app:

  ```dart
  final recent = MemorySink(capacity: 20000);
  installDebugSync(recent);
  ```
  ```sh
  dart run ailog:ailog_sync --vm-service <uri from flutter run> \
    -o app.jsonl --watch
  ```

  It registers a VM Service extension and the CLI pulls from the socket
  `flutter run` already opened, asking each time for everything past the
  last `seq` it holds — so it is a pull, not a push: nothing is dropped when
  the app is busy, attaching late still gets the buffer's whole history, and
  no prefix-stripping is needed because the events never touch a text
  stream. Debug and profile only; a release build serves no VM Service, and
  `installDebugSync` refuses to register there so the callback and the
  buffer it closes over fold out of the binary.

  If the buffer rolls over between polls the CLI says how many events were
  lost, rather than writing a file with a silent hole in it.

  `ailog_sync` also reads stdin (`flutter run | dart run ailog:ailog_sync`),
  which replaces the documented `tee`+`grep` recipe with one command, keeps
  non-JSONL output flowing to your terminal, and rejects JSON that is not
  ours so an app logging API responses cannot poison the file.

  The VM Service client is ~130 lines on `dart:io`'s `WebSocket` rather than
  `package:vm_service`, so the package stays zero-dependency. Tested against
  a real app process over a real socket — a fake client would exercise none
  of the parts that actually break.
- **The digest now reports its own incompleteness.** Size-based rotation
  deletes older files by design, so a digest built from the survivors is a
  partial view — measured: 100,000 events written, 63,686 reported, nothing
  saying so. `seq` makes the loss exactly computable (lowest seq 36315 → 36,314
  events missing), and it is now stated directly under the event count, in
  both Markdown and JSON, with `digest.missingEvents` for programmatic use.
  Gaps in the middle (a file not supplied) are counted too.
- **`ailog_digest --format pretty`** — not a digest, a replay: re-renders a
  recovered `.jsonl` file exactly the way `ConsoleSink` shows events live.
  Closes the one gap in the human-readability story: the file itself is
  machine-shaped by design, and there was no way to look at one with human
  eyes short of reading raw JSON. Colour on a terminal, plain with `-o`;
  interleaved non-JSON lines pass through untouched.
- **`logger.interaction(name)`** — records what the *user* did. Defaults to
  `trace`, so at a production level these stay out of the file while being
  retained as breadcrumbs, which puts the user's path through the app
  directly into the causal chain of whatever fails next. Takes an intent
  name rather than a caption, so it survives copy changes and translation.
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
- Digest honesty: breadcrumb entries are labeled as breadcrumbs, loggers
  that appear only inside causal chains are called out, and a group's
  context sample is labeled `first of N` (with the most recent shown when
  it differs).

### Fixed

- **The package did not compile for web at all.** `ids.dart` held
  `0xcbf29ce484222325` as an integer literal, which is a hard dart2js
  *compile* error ("can't be represented exactly in JavaScript") — so every
  Flutter web or dart2js build failed outright. Nothing caught it: `dart
  analyze` and `dart test` both run on the VM, where a 64-bit int is
  ordinary. FNV-1a is now computed over two 32-bit halves using arithmetic
  rather than wide bitwise ops, which is exact on both platforms. Hashes are
  **byte-identical** to before — verified against the previous output, the
  canonical FNV-1a 64 vectors, a dart2js build run under Node, and the
  Kotlin port compiled and executed for cross-language parity. CI now
  compiles for web so this cannot regress.
- **`Logger.create` crashed on dart2js under Node.** `Random.secure()`
  throws a raw JS `ReferenceError`, not the `UnsupportedError` the fallback
  caught, so the deterministic-`Random` path written for exactly this case
  never ran and construction took the program down with it.
- **Checkpoints named the dart2js runtime as the caller** whenever the
  bundle wasn't called `main.dart.js`. The guard keyed on Flutter web's
  default output name, so `dart compile js -o app.js` and any custom
  bundler name reported `→ app.js:3881 StackTrace_current` as the user's
  code — confidently wrong, which is the one outcome the guard exists to
  prevent. It now tests whether a frame resolves to a Dart source position
  at all.
- The schema legend listed `redacted` among the event keys, though it is a
  *convention* applying to any field rather than a key — a reader could go
  looking for an event field that never exists. It is now
  `_convention:redacted`, and a test asserts every key `toJson` can emit is
  documented (the previous test enumerated keys by hand and so could not
  catch a newly added one).
- **A value whose `toString()` throws crashed the host program.** Passing a
  domain object with a buggy override, an uninitialized `late` field, or a
  throwing getter in `context:` — or throwing one — propagated straight out
  of `logger.info()` / `logger.error()`. That is precisely the failure this
  package promises never to cause. All value paths (context values, map
  keys, past-depth-limit values, `Uri`, and the thrown error itself) now
  contain it and record `<toString() threw StateError>`, naming the
  exception rather than silently dropping the field.
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
