// `print` is this sink's whole purpose — see the class doc.
// ignore_for_file: avoid_print

import 'dart:convert';

import '../log_event.dart';
import 'log_sink.dart';

/// Prints each event as one raw JSONL line — the same bytes
/// [JsonlFileSink] would write, but through `print` instead of a file.
///
/// The problem this solves: on a real device there is often no direct route
/// from the app's private storage back to your machine (see "Getting the
/// log off a real device" in `ailog_flutter`'s README). But `flutter run`
/// already mirrors the app's `print` output into your terminal, live, over
/// the same connection every other debug tool uses. Pair this sink with
/// that and the file effectively arrives on its own:
///
/// ```sh
/// flutter run | tee session.log
/// grep -E '^\{' session.log > app.jsonl      # pull out just the JSONL lines
/// dart run ailog:ailog_digest app.jsonl
/// ```
///
/// This is a companion to [ConsoleSink.usingPrint] — that one prints the
/// human-readable rendering for you to read live; this one prints the exact
/// wire format for you to capture and feed back into `ailog_digest`. Use
/// both at once (in a [MultiSink]) if you want both.
///
/// **This is a debug-time convenience, not a replacement for
/// [JsonlFileSink].** A print-based transport can drop lines under load —
/// see [write] — and there is no `_hdr` legend line unless you add one
/// yourself, since there is no "start of file" to write it at.
class JsonlPrintSink implements LogSink {
  /// Creates a sink that prints one JSONL line per event.
  JsonlPrintSink({this.write = print});

  /// Where each line goes. Defaults to `print`.
  ///
  /// On Android, plain `print` calls made faster than the platform's log
  /// rate limit can be silently dropped — this is exactly why Flutter's own
  /// `debugPrint` exists, and why passing it here is worth doing on a
  /// device with any real log volume:
  ///
  /// ```dart
  /// JsonlPrintSink(write: debugPrint)
  /// ```
  ///
  /// Do **not** pass a `wrapWidth` if you wire `debugPrint` up yourself —
  /// `debugPrint`'s default call site doesn't, but if you ever do, word
  /// wrapping would split one JSONL line into several and corrupt it.
  final void Function(String line) write;

  @override
  void add(LogEvent event) {
    late final String line;
    try {
      line = jsonEncode(event.toJson());
    } catch (_) {
      // The sanitizer should have made this impossible; degrade rather than
      // dropping the event entirely. Mirrors JsonlFileSink's fallback, so a
      // reader sees the same shape from either source.
      line = jsonEncode({
        'ts': DateTime.now().toUtc().toIso8601String(),
        'lvl': 'warn',
        'msg': 'ailog: event could not be encoded',
        'lg': 'ailog',
      });
    }
    try {
      write(line);
    } catch (_) {
      // A logger must never break the program it is observing — and a
      // custom writer is caller code, so it can throw.
    }
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}
