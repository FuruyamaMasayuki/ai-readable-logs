import 'package:ailog/ailog.dart';
import 'package:test/test.dart';

LogEvent _event({
  String message = 'boom',
  String logger = 'app',
  LogLevel level = LogLevel.error,
  String? fingerprint,
  DateTime? time,
}) =>
    LogEvent(
      time: time ?? DateTime.utc(2026),
      level: level,
      message: message,
      logger: logger,
      sessionId: 's',
      sequence: 1,
      error: fingerprint == null
          ? null
          : ErrorInfo(type: 'E', message: message, fingerprint: fingerprint),
    );

void main() {
  group('RateLimitSink', () {
    test('lets the burst through and collapses the rest', () {
      final inner = MemorySink();
      var now = DateTime.utc(2026);
      final sink = RateLimitSink(inner, burst: 3, clock: () => now);

      // The Flutter case: a broken widget rebuilding every frame.
      for (var i = 0; i < 60; i++) {
        sink.add(_event(fingerprint: 'same-bug'));
      }

      expect(inner.events, hasLength(3),
          reason:
              'only the burst reaches the inner sink while the window is open');
    });

    test('reports the suppressed count instead of losing it', () async {
      final inner = MemorySink();
      var now = DateTime.utc(2026);
      final sink = RateLimitSink(inner, burst: 2, clock: () => now);

      for (var i = 0; i < 10; i++) {
        sink.add(_event(fingerprint: 'same-bug'));
      }
      await sink.flush();

      final summary = inner.events.last;
      expect(summary.message, contains('+8 more suppressed'));
      expect(summary.context['suppressedCount'], 8);
      expect(summary.tags, contains('rate-limited'));
    });

    test('a new window restores the budget', () {
      final inner = MemorySink();
      var now = DateTime.utc(2026);
      final sink = RateLimitSink(
        inner,
        burst: 1,
        window: const Duration(seconds: 10),
        clock: () => now,
      );

      sink.add(_event(fingerprint: 'f'));
      sink.add(_event(fingerprint: 'f')); // suppressed
      now = now.add(const Duration(seconds: 11));
      sink.add(_event(fingerprint: 'f')); // new window

      // 1 passed + 1 window summary + 1 passed
      expect(inner.events.where((e) => !e.tags.contains('rate-limited')),
          hasLength(2));
    });

    test('different fingerprints have independent budgets', () {
      final inner = MemorySink();
      var now = DateTime.utc(2026);
      final sink = RateLimitSink(inner, burst: 1, clock: () => now);

      sink.add(_event(fingerprint: 'a'));
      sink.add(_event(fingerprint: 'b'));
      sink.add(_event(fingerprint: 'c'));

      expect(inner.events, hasLength(3),
          reason: 'one noisy error must not throttle unrelated ones');
    });

    test('events without an error are keyed by logger, level and message', () {
      final inner = MemorySink();
      var now = DateTime.utc(2026);
      final sink = RateLimitSink(inner, burst: 1, clock: () => now);

      sink.add(_event(message: 'polling', level: LogLevel.info));
      sink.add(_event(message: 'polling', level: LogLevel.info)); // suppressed
      sink.add(_event(message: 'different', level: LogLevel.info));

      expect(inner.events.map((e) => e.message), ['polling', 'different']);
    });

    test('evicting a tracked key still reports what it suppressed', () {
      final inner = MemorySink();
      var now = DateTime.utc(2026);
      final sink = RateLimitSink(
        inner,
        burst: 1,
        maxTrackedKeys: 2,
        clock: () => now,
      );

      sink.add(_event(fingerprint: 'evicted'));
      sink.add(_event(fingerprint: 'evicted')); // suppressed, count = 1
      sink.add(_event(fingerprint: 'b'));
      sink.add(_event(fingerprint: 'c')); // pushes 'evicted' out

      final summaries =
          inner.events.where((e) => e.tags.contains('rate-limited'));
      expect(summaries, hasLength(1),
          reason: 'a silently discarded tally is worse than no rate limiting');
    });

    test('close() flushes pending summaries', () async {
      final inner = MemorySink();
      var now = DateTime.utc(2026);
      final sink = RateLimitSink(inner, burst: 1, clock: () => now);

      sink.add(_event(fingerprint: 'f'));
      sink.add(_event(fingerprint: 'f'));
      await sink.close();

      expect(inner.events.any((e) => e.tags.contains('rate-limited')), isTrue);
    });

    test('a quiet key produces no summary noise', () async {
      final inner = MemorySink();
      var now = DateTime.utc(2026);
      final sink = RateLimitSink(inner, burst: 3, clock: () => now);

      sink.add(_event(fingerprint: 'f'));
      await sink.flush();

      expect(inner.events, hasLength(1));
      expect(inner.events.single.tags, isNot(contains('rate-limited')));
    });
  });
}
