import '../log_event.dart';
import 'log_sink.dart';

/// Web stub. There is no filesystem, so file logging is unavailable.
///
/// The class still exists so that shared code compiles for web without
/// conditional imports at every call site; use `MemorySink` or a custom sink
/// that POSTs to a collector instead.
class JsonlFileSink implements LogSink {
  /// Always throws [UnsupportedError]. Kept so code that mentions
  /// `JsonlFileSink` still compiles for web; construct a different sink at
  /// runtime instead of reaching this.
  JsonlFileSink({
    required String path,
    int maxBytes = 8 * 1024 * 1024,
    int maxFiles = 5,
    Duration flushInterval = const Duration(seconds: 2),
    bool writeSchemaHeader = true,
  }) {
    throw UnsupportedError(
      'JsonlFileSink is not available on the web. Use MemorySink, ConsoleSink '
      'or a custom LogSink that forwards events to a collector.',
    );
  }

  /// Unreachable — the constructor always throws.
  String get path => throw UnsupportedError('unreachable');

  @override
  void add(LogEvent event) {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}
