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
