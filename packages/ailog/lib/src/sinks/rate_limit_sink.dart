import 'dart:collection';

import '../log_event.dart';
import 'log_sink.dart';

/// Collapses floods of the same event into one line plus a count.
///
/// The motivating case is real and easy to hit: Flutter rebuilds a broken
/// widget every frame, so `ErrorWidget.builder` reports the same failure 60
/// times a second, each with a fingerprint, frames and a full causal chain.
/// Within a minute the log is megabytes of one error, and the events that
/// explain the *actual* bug have rotated out of the file. Nothing about the
/// hundredth copy is informative — but knowing it happened a hundred times
/// is.
///
/// Events are keyed by error fingerprint when present, and by
/// logger+level+message otherwise. The first occurrence in each window
/// passes through immediately; the rest are counted. When the window closes,
/// a single summary event reports how many were suppressed, so the volume is
/// never silently lost.
class RateLimitSink implements LogSink {
  /// Wraps [inner] with per-key rate limiting.
  ///
  /// Pass [clock] only in tests, to drive the window without waiting.
  RateLimitSink(
    this.inner, {
    this.window = const Duration(seconds: 10),
    this.burst = 3,
    this.maxTrackedKeys = 256,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// The wrapped destination. Suppressed events never reach it; the summary
  /// event does.
  final LogSink inner;

  /// How long one key's budget lasts.
  final Duration window;

  /// How many events with the same key pass through per [window] before the
  /// rest are collapsed. Keeping this above 1 matters — the second and third
  /// occurrence often carry different context than the first, which is
  /// exactly what tells you whether a failure is deterministic.
  final int burst;

  /// Bounds memory when a program produces endlessly varied keys.
  final int maxTrackedKeys;

  final DateTime Function() _clock;

  /// Insertion-ordered so the oldest key is evicted first.
  final LinkedHashMap<String, _Bucket> _buckets = LinkedHashMap();

  @override
  void add(LogEvent event) {
    final now = _clock();
    final key = _keyFor(event);

    final bucket = _buckets.remove(key) ?? _Bucket(windowStart: now);
    _buckets[key] = bucket;

    if (now.difference(bucket.windowStart) >= window) {
      _flush(key, bucket, now);
      bucket
        ..windowStart = now
        ..passed = 0
        ..suppressed = 0
        ..lastSuppressed = null;
    }

    if (bucket.passed < burst) {
      bucket.passed++;
      inner.add(event);
    } else {
      bucket.suppressed++;
      bucket.lastSuppressed = event;
    }

    while (_buckets.length > maxTrackedKeys) {
      final oldest = _buckets.keys.first;
      final evicted = _buckets.remove(oldest)!;
      // Report what was suppressed rather than dropping the count on the
      // floor — a silently discarded tally is worse than no rate limiting.
      _flush(oldest, evicted, now);
    }
  }

  /// Emits the summary for a closed window, if anything was suppressed.
  void _flush(String key, _Bucket bucket, DateTime now) {
    final suppressed = bucket.suppressed;
    if (suppressed == 0) return;
    final sample = bucket.lastSuppressed;
    if (sample == null) return;

    inner.add(
      LogEvent(
        time: now,
        level: sample.level,
        message: '${sample.message} (+$suppressed more suppressed)',
        logger: sample.logger,
        sessionId: sample.sessionId,
        sequence: sample.sequence,
        traceId: sample.traceId,
        spanId: sample.spanId,
        parentSpanId: sample.parentSpanId,
        context: {
          ...sample.context,
          'suppressedCount': suppressed,
          'suppressedWindowMs': window.inMilliseconds,
        },
        tags: [...sample.tags, 'rate-limited'],
        error: sample.error,
        durationMs: sample.durationMs,
      ),
    );
  }

  String _keyFor(LogEvent event) {
    final fingerprint = event.error?.fingerprint;
    // Fingerprints already answer "is this the same failure", so reuse them
    // rather than inventing a second notion of sameness.
    if (fingerprint != null && fingerprint.isNotEmpty) {
      return 'fp:$fingerprint';
    }
    return '${event.logger}|${event.level.wireName}|${event.message}';
  }

  @override
  Future<void> flush() {
    final now = _clock();
    for (final entry in _buckets.entries) {
      _flush(entry.key, entry.value, now);
      entry.value
        ..suppressed = 0
        ..lastSuppressed = null;
    }
    return inner.flush();
  }

  @override
  Future<void> close() async {
    await flush();
    await inner.close();
  }
}

class _Bucket {
  _Bucket({required this.windowStart});

  DateTime windowStart;
  int passed = 0;
  int suppressed = 0;
  LogEvent? lastSuppressed;
}
