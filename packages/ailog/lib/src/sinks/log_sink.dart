import 'dart:async';

import '../export.dart';
import '../log_event.dart';
import '../log_level.dart';

/// Destination for log events.
///
/// Implementations must never throw from [add]: a logger that can break the
/// program it is observing is worse than no logger.
abstract interface class LogSink {
  /// Called for every event that passes the logger's level filter.
  void add(LogEvent event);

  /// Pushes buffered data to the underlying medium.
  Future<void> flush();

  /// Flushes and releases resources. The sink is unusable afterwards.
  Future<void> close();
}

/// Fans one event out to several sinks.
///
/// A failing sink is isolated: the others still receive the event, and the
/// failure is reported once via [onSinkError] rather than on every line.
class MultiSink implements LogSink {
  /// Fans every event out to [sinks], in order.
  ///
  /// The sinks are independent — they do not have to agree on what to keep.
  /// Wrap one in a [LevelFilterSink] to give it its own threshold.
  MultiSink(this.sinks, {this.onSinkError});

  /// The destinations, in the order they receive each event.
  final List<LogSink> sinks;

  /// Called once when a sink first throws from `add`.
  ///
  /// That sink is then skipped for the rest of the process: a disk that
  /// filled up would otherwise throw on every subsequent line, and a handler
  /// that logs the failure would recurse. The other sinks are unaffected, so
  /// a broken file sink does not cost you the console too.
  ///
  /// Leave it `null` to fail silently, which is the safe default for a
  /// logger — but wiring it to a `print` while developing is worth it, since
  /// otherwise a misconfigured sink looks exactly like an idle one.
  final void Function(LogSink sink, Object error, StackTrace stack)?
      onSinkError;
  final Set<LogSink> _broken = Set.identity();

  @override
  void add(LogEvent event) {
    for (final sink in sinks) {
      if (_broken.contains(sink)) continue;
      try {
        sink.add(event);
      } catch (error, stack) {
        _broken.add(sink);
        onSinkError?.call(sink, error, stack);
      }
    }
  }

  @override
  Future<void> flush() async {
    for (final sink in sinks) {
      try {
        await sink.flush();
      } catch (_) {
        // Already reported through onSinkError; nothing useful to do here.
      }
    }
  }

  @override
  Future<void> close() async {
    for (final sink in sinks) {
      try {
        await sink.close();
      } catch (_) {
        // Best effort.
      }
    }
  }
}

/// Keeps events in memory, and hands them back as text.
///
/// This is the sink to attach when the log needs to become a [String] — a
/// "copy diagnostics" button, an attachment on a crash report, or the last
/// minute of activity pasted into a chat with an assistant. Nothing here
/// touches the filesystem, so it works identically on web.
///
/// ```dart
/// final buffer = MemorySink(capacity: 2000);
/// final logger = Logger.create(sink: MultiSink([fileSink, buffer]));
/// ...
/// final text = buffer.export(LogFilter.forAi).toReport();
/// ```
class MemorySink implements LogSink {
  /// Retains up to [capacity] of the most recent events.
  MemorySink({this.capacity = 1000});

  /// Most recent events retained. Older ones are discarded, so a long-running
  /// app has a bounded, rolling window rather than a leak.
  final int capacity;

  /// The retained events, oldest first.
  ///
  /// Exposed directly so tests can assert on it. For anything user-facing
  /// prefer [export], which applies a filter and reports what it dropped.
  final List<LogEvent> events = [];

  /// Applies [filter] and returns the survivors together with whole-log
  /// aggregates and a record of what was removed.
  LogSelection export([LogFilter filter = LogFilter.none]) =>
      filter.apply(events);

  /// Everything currently held, as JSONL text.
  String toJsonl({bool includeHeader = true}) =>
      export().toJsonl(includeHeader: includeHeader);

  /// Everything currently held, as a Markdown digest.
  String toMarkdown({int maxGroups = 20}) =>
      export().toMarkdown(maxGroups: maxGroups);

  @override
  void add(LogEvent event) {
    events.add(event);
    if (events.length > capacity) {
      events.removeRange(0, events.length - capacity);
    }
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}

  /// Discards every retained event. The sink stays usable.
  void clear() => events.clear();
}

/// Wraps another sink with its own minimum level.
///
/// Typical use: everything goes to the JSONL file, only warnings and above
/// reach the console.
class LevelFilterSink implements LogSink {
  /// Passes only events at [minimumLevel] or above through to [inner].
  LevelFilterSink(this.inner, this.minimumLevel);

  /// The wrapped destination. [flush] and [close] are forwarded to it, so
  /// wrapping a sink does not change how it is shut down.
  final LogSink inner;

  /// The threshold for this destination alone.
  ///
  /// Independent of the `Logger`'s own `minimumLevel`, which still decides
  /// what gets emitted at all — this can only narrow that further.
  final LogLevel minimumLevel;

  @override
  void add(LogEvent event) {
    if (event.level.passes(minimumLevel)) inner.add(event);
  }

  @override
  Future<void> flush() => inner.flush();

  @override
  Future<void> close() => inner.close();
}
