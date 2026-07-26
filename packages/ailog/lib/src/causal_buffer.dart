/// Keeps the recent past around so that errors can explain themselves.
///
/// The single most expensive step when debugging from logs is scrolling
/// backwards to find what led to a failure — and it is exactly the step that
/// costs the most tokens when a model does it, because it has to be handed the
/// whole file to do it. Instead, every error event carries its own preceding
/// events inline. One line of JSONL becomes self-contained evidence.
library;

import 'dart:collection';

import 'breadcrumb.dart';
import 'sanitizer.dart';

/// A bounded ring of recent breadcrumbs, partitioned by trace.
class CausalBuffer {
  /// Creates a buffer retaining [perTraceCapacity] breadcrumbs for each of at
  /// most [maxTraces] traces — so worst-case memory is the product of the two.
  CausalBuffer({this.perTraceCapacity = 20, this.maxTraces = 64});

  /// How many recent breadcrumbs are retained per trace.
  final int perTraceCapacity;

  /// How many distinct traces are retained. Least recently used traces are
  /// dropped first, which bounds memory in long-running servers.
  ///
  /// Above this many concurrent traces, chain quality degrades sharply rather
  /// than gradually: traces evict each other before their error arrives, and
  /// the error line simply has no chain. A server handling more than this many
  /// requests at once should raise it (`Logger.create`'s
  /// `causalChainTraces`); [evictedTraces] reports when it is happening.
  final int maxTraces;

  /// Insertion-ordered so the first key is the least recently touched trace.
  final LinkedHashMap<String, Queue<Breadcrumb>> _byTrace = LinkedHashMap();

  static const String _noTrace = '';

  int _evictedTraces = 0;

  /// How many traces have been dropped to stay within [maxTraces].
  ///
  /// Non-zero means some errors lost their causal chain — worth surfacing,
  /// because the symptom (an error line with no chain) is otherwise
  /// indistinguishable from a trace that genuinely had no history.
  int get evictedTraces => _evictedTraces;

  /// Retains [breadcrumb] under [traceId], evicting the oldest breadcrumb in
  /// that trace once it is full.
  ///
  /// Breadcrumbs without a trace share one bucket. They are still usable —
  /// an untraced error gets an untraced chain — but concurrent operations
  /// interleave there, which is the practical argument for using traces.
  void record(Breadcrumb breadcrumb, {String? traceId}) {
    final key = traceId ?? _noTrace;
    // Re-insert to move this trace to the most-recently-used end.
    final queue = _byTrace.remove(key) ?? Queue<Breadcrumb>();
    queue.addLast(breadcrumb);
    while (queue.length > perTraceCapacity) {
      queue.removeFirst();
    }
    _byTrace[key] = queue;

    while (_byTrace.length > maxTraces) {
      _byTrace.remove(_byTrace.keys.first);
      _evictedTraces++;
    }
  }

  /// The [limit] most recent breadcrumbs for [traceId], oldest first.
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
  List<Breadcrumb> recentFor(String? traceId, {int limit = 10}) {
    final queue = _byTrace[traceId ?? _noTrace];
    if (queue == null || queue.isEmpty) return const [];
    final crumbs = queue.toList();
    if (crumbs.length <= limit) return crumbs;
    return crumbs.sublist(crumbs.length - limit);
  }

  /// Renders the chain to embed in an event at [time] within [traceId].
  ///
  /// Sanitization happens here rather than at record time, so breadcrumbs
  /// that are never pulled into a chain cost nothing beyond their allocation.
  List<Map<String, Object?>> chainFor({
    required DateTime time,
    required String? traceId,
    required Sanitizer sanitizer,
    int limit = 10,
    Breadcrumb? exclude,
  }) {
    final recent = recentFor(traceId, limit: limit);
    return [
      for (final crumb in recent)
        if (!identical(crumb, exclude)) crumb.render(time, sanitizer),
    ];
  }

  /// Drops every retained breadcrumb and resets [evictedTraces].
  void clear() {
    _byTrace.clear();
    _evictedTraces = 0;
  }
}
