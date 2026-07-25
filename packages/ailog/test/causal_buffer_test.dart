import 'package:ailog/ailog.dart';
import 'package:test/test.dart';

LogEvent _event(
  String message, {
  String? traceId,
  int seq = 0,
  DateTime? time,
  LogLevel level = LogLevel.info,
}) =>
    LogEvent(
      time: time ?? DateTime.utc(2026, 1, 1, 0, 0, seq),
      level: level,
      message: message,
      logger: 'app',
      sessionId: 's',
      sequence: seq,
      traceId: traceId,
    );

void main() {
  group('CausalBuffer', () {
    test('recentFor returns events in insertion order, oldest first', () {
      final buffer = CausalBuffer(perTraceCapacity: 10);
      buffer.record(_event('a', traceId: 't1', seq: 1));
      buffer.record(_event('b', traceId: 't1', seq: 2));
      buffer.record(_event('c', traceId: 't1', seq: 3));

      final recent = buffer.recentFor('t1');
      expect(recent.map((e) => e.message).toList(), ['a', 'b', 'c']);
    });

    test('caps events per trace at perTraceCapacity', () {
      final buffer = CausalBuffer(perTraceCapacity: 2);
      buffer.record(_event('a', traceId: 't1', seq: 1));
      buffer.record(_event('b', traceId: 't1', seq: 2));
      buffer.record(_event('c', traceId: 't1', seq: 3));

      final recent = buffer.recentFor('t1');
      expect(recent.map((e) => e.message).toList(), ['b', 'c']);
    });

    test('does not mix events from different traces', () {
      final buffer = CausalBuffer();
      buffer.record(_event('a', traceId: 't1', seq: 1));
      buffer.record(_event('b', traceId: 't2', seq: 2));

      expect(buffer.recentFor('t1').map((e) => e.message), ['a']);
      expect(buffer.recentFor('t2').map((e) => e.message), ['b']);
    });

    test('evicts least recently touched trace beyond maxTraces', () {
      final buffer = CausalBuffer(maxTraces: 2);
      buffer.record(_event('a', traceId: 't1', seq: 1));
      buffer.record(_event('b', traceId: 't2', seq: 2));
      buffer.record(_event('c', traceId: 't3', seq: 3));

      expect(buffer.recentFor('t1'), isEmpty);
      expect(buffer.recentFor('t2'), isNotEmpty);
      expect(buffer.recentFor('t3'), isNotEmpty);
    });

    test('chainFor excludes the event itself and renders relative offsets', () {
      final buffer = CausalBuffer();
      final base = DateTime.utc(2026, 1, 1, 0, 0, 0);
      final e1 = _event('first', traceId: 't1', seq: 1, time: base);
      final e2 = _event(
        'second',
        traceId: 't1',
        seq: 2,
        time: base.add(const Duration(milliseconds: 500)),
      );
      buffer.record(e1);
      buffer.record(e2);

      final chain = buffer.chainFor(e2);
      expect(chain.length, 1);
      expect(chain.first['msg'], 'first');
      expect(chain.first['dt'], -500);
    });
  });
}
