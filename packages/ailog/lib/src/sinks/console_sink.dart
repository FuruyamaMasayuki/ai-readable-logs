import '../console_formatter.dart';
import '../log_event.dart';
import '../platform.dart';
import 'log_sink.dart';

/// Writes the human-readable rendering to stdout.
///
/// Pair this with [LevelFilterSink] and a [JsonlFileSink] so the console only
/// shows what a developer watching the terminal needs, while the file keeps
/// everything for later analysis.
class ConsoleSink implements LogSink {
  ConsoleSink({bool? useColor, bool showTraceId = true})
      : _formatter = ConsoleFormatter(
          useColor: useColor ?? platformSupportsAnsi(),
          showTraceId: showTraceId,
        );

  final ConsoleFormatter _formatter;

  @override
  void add(LogEvent event) => writeToStdout(_formatter.format(event));

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}
