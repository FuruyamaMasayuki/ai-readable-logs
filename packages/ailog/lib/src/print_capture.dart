/// Makes ordinary `print()` calls part of the structured log.
///
/// Nobody instruments a codebase all at once. Existing code, third-party
/// packages, and quick debugging all speak `print`, and every one of those
/// lines is invisible to the JSONL file — which means invisible to whatever
/// AI later reads it. Capturing them costs the caller one wrapper at the top
/// of `main`, and each captured line still carries the ambient trace and
/// session ids like any other event.
library;

import 'dart:async';

import 'log_level.dart';
import 'logger.dart';

/// Runs [body] with `print()` calls also logged through [logger].
///
/// Captured lines are logged at [level] with a `print` tag, so they are easy
/// to find — and easy to filter out once real log calls replace them.
///
/// [forwardToConsole] controls whether the original raw line still reaches
/// the console. Keep it `true` (default) when [logger] has no console sink.
/// Set it to `false` when a `ConsoleSink` is attached, or every `print` will
/// appear twice — once raw, once formatted.
///
/// Prints emitted by the logging pipeline itself (e.g. `ConsoleSink` writing
/// a formatted line) are passed straight through, never re-captured, so a
/// console sink cannot feed back into the log:
///
/// ```dart
/// void main() {
///   final logger = Logger.create(sink: JsonlFileSink(path: '.ailog/app.jsonl'));
///   capturePrints(logger, () {
///     print('legacy debugging line');   // → console AND app.jsonl
///     runApp(...);
///   });
/// }
/// ```
R capturePrints<R>(
  Logger logger,
  R Function() body, {
  LogLevel level = LogLevel.info,
  bool forwardToConsole = true,
  String loggerName = 'print',
}) {
  final child = logger.child(loggerName);
  // Re-entrancy flag rather than a zone value: the sinks run synchronously
  // inside the log call, so a plain bool is enough, and it costs nothing.
  var logging = false;

  return runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        if (logging) {
          // A print issued *by* the logging pipeline (console sink, an
          // onError handler). It must reach the console and must not be
          // logged again — that way lies infinite recursion.
          parent.print(zone, line);
          return;
        }
        if (forwardToConsole) parent.print(zone, line);
        logging = true;
        try {
          child.log(level, line, tags: const ['print']);
        } finally {
          logging = false;
        }
      },
    ),
  );
}
