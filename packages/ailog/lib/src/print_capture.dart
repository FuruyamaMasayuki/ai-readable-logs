/// Makes ordinary `print()` calls part of the structured log.
///
/// Nobody instruments a codebase all at once. Existing code, third-party
/// packages, and quick debugging all speak `print`, and every one of those
/// lines is invisible to the JSONL file — which means invisible to whatever
/// AI later reads it. Capturing them costs the caller one wrapper at the top
/// of `main`, and each captured line behaves like any other event: same
/// session id, and whatever trace is active where the `print()` runs.
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
/// This starts no trace of its own. A captured line inherits whatever scope
/// is active where the `print()` actually runs — the same rule every other
/// log call follows — so a print outside any `runWithScope` has no trace id.
///
/// Capture follows the [Zone], which has two consequences worth knowing.
/// Work *scheduled* inside [body] stays captured even though it runs later,
/// because a `Timer` or `Future` binds to the zone that created it. But an
/// isolate started with `Isolate.spawn` (or Flutter's `compute`) begins a
/// fresh zone tree, so prints made there are **not** captured; call this
/// again inside that isolate if you need them.
///
/// One `print()` is one event. `print('a\nb')` yields a single line whose
/// message contains the newline, not two events.
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
