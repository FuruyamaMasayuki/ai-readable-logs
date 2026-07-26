import '../console_formatter.dart';
import '../log_event.dart';
import '../platform.dart';
import 'log_sink.dart';

/// Writes the human-readable rendering to the console.
///
/// Pair this with [LevelFilterSink] and a [JsonlFileSink] so the console only
/// shows what a developer watching the terminal needs, while the file keeps
/// everything for later analysis.
///
/// By default this writes straight to stdout, which is right for CLIs and
/// servers. **On a Flutter device it is not** — `stdout` is not routed to
/// logcat or the unified log, so the lines go nowhere visible. Use
/// [ConsoleSink.usingPrint] there, or pass your own [write]:
///
/// ```dart
/// ConsoleSink.usingPrint()                       // print()
/// ConsoleSink(write: debugPrint)                 // Flutter's rate-limited print
/// ConsoleSink(write: (l) => developer.log(l))    // dart:developer
/// ```
class ConsoleSink implements LogSink {
  /// Creates a console sink.
  ///
  /// [useColor] defaults to whether the platform looks like an ANSI-capable
  /// terminal, so a redirected stdout does not fill a file with escape
  /// codes. [showTraceId] prints a short trace prefix, which is what makes
  /// interleaved concurrent operations readable; turn it off for a quieter
  /// single-threaded CLI.
  ConsoleSink({bool? useColor, bool showTraceId = true, this.write})
      : _formatter = ConsoleFormatter(
          useColor: useColor ?? platformSupportsAnsi(),
          showTraceId: showTraceId,
        );

  /// A [ConsoleSink] that emits through `print`.
  ///
  /// The portable choice: `print` reaches the Flutter console, `flutter
  /// logs`, logcat and the Xcode console, where a raw `stdout` write does
  /// not. Colour is off by default because those destinations render ANSI
  /// escapes as literal garbage rather than colour.
  factory ConsoleSink.usingPrint({
    bool useColor = false,
    bool showTraceId = true,
  }) =>
      ConsoleSink(
        useColor: useColor,
        showTraceId: showTraceId,
        // ignore: avoid_print
        write: print,
      );

  final ConsoleFormatter _formatter;

  /// Where each formatted line goes. Defaults to stdout.
  ///
  /// Note that using `print` here inside a [capturePrints] zone is safe: the
  /// capture guard passes the logging pipeline's own prints straight through
  /// rather than logging them again.
  final void Function(String line)? write;

  @override
  void add(LogEvent event) {
    final line = _formatter.format(event);
    final sink = write;
    if (sink == null) {
      writeToStdout(line);
      return;
    }
    try {
      sink(line);
    } catch (_) {
      // A logger must never break the program it is observing — and a custom
      // writer is caller code, so it can throw.
    }
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}
