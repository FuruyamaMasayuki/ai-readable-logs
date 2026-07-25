import 'package:ailog/ailog.dart';
import 'package:test/test.dart';

Breadcrumb _crumb(
  String message, {
  int seconds = 0,
  DateTime? time,
  LogLevel level = LogLevel.info,
  Map<String, Object?> context = const {},
}) =>
    Breadcrumb(
      time: time ?? DateTime.utc(2026, 1, 1, 0, 0, seconds),
      level: level,
      message: message,
      logger: 'app',
      context: context,
    );

final _sanitizer = Sanitizer(redactor: Redactor.disabled());

void main() {
  group('CausalBuffer', () {
    test('recentFor returns breadcrumbs in insertion order, oldest first', () {
      final buffer = CausalBuffer(perTraceCapacity: 10);
      buffer.record(_crumb('a', seconds: 1), traceId: 't1');
      buffer.record(_crumb('b', seconds: 2), traceId: 't1');
      buffer.record(_crumb('c', seconds: 3), traceId: 't1');

      expect(buffer.recentFor('t1').map((c) => c.message), ['a', 'b', 'c']);
    });

    test('caps breadcrumbs per trace at perTraceCapacity', () {
      final buffer = CausalBuffer(perTraceCapacity: 2);
      buffer.record(_crumb('a', seconds: 1), traceId: 't1');
      buffer.record(_crumb('b', seconds: 2), traceId: 't1');
      buffer.record(_crumb('c', seconds: 3), traceId: 't1');

      expect(buffer.recentFor('t1').map((c) => c.message), ['b', 'c']);
    });

    test('does not mix breadcrumbs from different traces', () {
      final buffer = CausalBuffer();
      buffer.record(_crumb('a'), traceId: 't1');
      buffer.record(_crumb('b'), traceId: 't2');

      expect(buffer.recentFor('t1').map((c) => c.message), ['a']);
      expect(buffer.recentFor('t2').map((c) => c.message), ['b']);
    });

    test('evicts the least recently touched trace beyond maxTraces', () {
      final buffer = CausalBuffer(maxTraces: 2);
      buffer.record(_crumb('a'), traceId: 't1');
      buffer.record(_crumb('b'), traceId: 't2');
      buffer.record(_crumb('c'), traceId: 't3');

      expect(buffer.recentFor('t1'), isEmpty);
      expect(buffer.recentFor('t2'), isNotEmpty);
      expect(buffer.recentFor('t3'), isNotEmpty);
    });

    test('counts evicted traces so lost chains are diagnosable', () {
      // An error line with no chain is otherwise indistinguishable from a
      // trace that genuinely had no history.
      final buffer = CausalBuffer(maxTraces: 2);
      expect(buffer.evictedTraces, 0);

      for (var i = 0; i < 5; i++) {
        buffer.record(_crumb('x'), traceId: 't$i');
      }

      expect(buffer.evictedTraces, 3);
    });

    test('chainFor renders relative offsets', () {
      final buffer = CausalBuffer();
      final base = DateTime.utc(2026, 1, 1, 0, 0, 0);
      buffer.record(_crumb('first', time: base), traceId: 't1');

      final chain = buffer.chainFor(
        time: base.add(const Duration(milliseconds: 500)),
        traceId: 't1',
        sanitizer: _sanitizer,
      );

      expect(chain, hasLength(1));
      expect(chain.single['msg'], 'first');
      expect(chain.single['dt'], -500);
    });

    test('chainFor applies redaction at render time, not record time', () {
      // Breadcrumbs are held raw so that never-rendered ones cost nothing;
      // anything that does get rendered must still be masked.
      final buffer = CausalBuffer();
      buffer.record(
        _crumb('login for alice@example.com', context: {'password': 'hunter2'}),
        traceId: 't1',
      );

      final chain = buffer.chainFor(
        time: DateTime.utc(2026, 1, 1, 0, 0, 1),
        traceId: 't1',
        sanitizer: Sanitizer(redactor: Redactor(salt: 'fixed')),
      );

      expect(chain.single['msg'], isNot(contains('alice@example.com')));
      expect(chain.single['msg'], contains('[redacted:email'));
      expect((chain.single['ctx'] as Map)['password'],
          contains('[redacted:field'));
    });

    test('a context map mutated after logging does not corrupt the crumb', () {
      // Callers routinely reuse or clear a map; a breadcrumb reporting its
      // later contents would be actively misleading.
      final buffer = CausalBuffer();
      final context = <String, Object?>{'step': 1};
      buffer.record(_crumb('m', context: context), traceId: 't1');
      context['step'] = 999;

      final chain = buffer.chainFor(
        time: DateTime.utc(2026, 1, 1, 0, 0, 1),
        traceId: 't1',
        sanitizer: _sanitizer,
      );

      expect((chain.single['ctx'] as Map)['step'], 1);
    });

    test('clear() empties the buffer and resets the eviction count', () {
      final buffer = CausalBuffer(maxTraces: 1);
      buffer.record(_crumb('a'), traceId: 't1');
      buffer.record(_crumb('b'), traceId: 't2');
      expect(buffer.evictedTraces, greaterThan(0));

      buffer.clear();

      expect(buffer.recentFor('t2'), isEmpty);
      expect(buffer.evictedTraces, 0);
    });
  });
}
