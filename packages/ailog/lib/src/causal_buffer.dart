/// Keeps the recent past around so that errors can explain themselves.
///
/// The single most expensive step when debugging from logs is scrolling
/// backwards to find what led to a failure — and it is exactly the step that
/// costs the most tokens when a model does it, because it has to be handed the
/// whole file to do it. Instead, every error event carries its own preceding
/// events inline. One line of JSONL becomes self-contained evidence.
library;

import 'dart:collection';

import 'log_event.dart';

/// A bounded ring of recent events, partitioned by trace.
class CausalBuffer {
  CausalBuffer({this.perTraceCapacity = 20, this.maxTraces = 64});

  /// How many recent events are retained per trace.
  final int perTraceCapacity;

  /// How many distinct traces are retained. Least recently used traces are
  /// dropped first, which bounds memory in long-running servers.
  final int maxTraces;

  /// Insertion-ordered so the first key is the least recently touched trace.
  final LinkedHashMap<String, Queue<LogEvent>> _byTrace = LinkedHashMap();

  static const String _noTrace = '';

  void record(LogEvent event) {
    final key = event.traceId ?? _noTrace;
    // Re-insert to move this trace to the most-recently-used end.
    final queue = _byTrace.remove(key) ?? Queue<LogEvent>();
    queue.addLast(event);
    while (queue.length > perTraceCapacity) {
      queue.removeFirst();
    }
    _byTrace[key] = queue;

    while (_byTrace.length > maxTraces) {
      _byTrace.remove(_byTrace.keys.first);
    }
  }

  /// The [limit] most recent events for [traceId], oldest first.
  ///
  /// Events from *different* traces are never mixed: a chain that silently
  /// blends unrelated operations is worse than a short one.
  ///
  /// Untraced events (`traceId == null`) are the exception, and it is worth
  /// understanding before reading a chain on one. They all share a single
  /// bucket, so an error logged outside any `startTrace`/`runWithScope` gets
  /// a chain built from whatever was logged most recently anywhere in the
  /// app — which may be unrelated. That is still useful in a simple,
  /// sequential program, and misleading in a concurrent one. Wrap concurrent
  /// work in a trace to get chains you can trust.
  List<LogEvent> recentFor(String? traceId, {int limit = 10}) {
    final queue = _byTrace[traceId ?? _noTrace];
    if (queue == null || queue.isEmpty) return const [];
    final events = queue.toList();
    if (events.length <= limit) return events;
    return events.sublist(events.length - limit);
  }

  /// Renders the chain that gets embedded in [event].
  List<Map<String, Object?>> chainFor(LogEvent event, {int limit = 10}) {
    final recent = recentFor(event.traceId, limit: limit);
    return [
      for (final past in recent)
        if (!identical(past, event)) past.toChainEntry(event.time),
    ];
  }

  void clear() => _byTrace.clear();
}
