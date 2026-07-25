import 'package:ailog/ailog.dart';
import 'package:test/test.dart';

LogEvent _event(String message, {LogLevel level = LogLevel.info}) => LogEvent(
      time: DateTime.utc(2026, 1, 1),
      level: level,
      message: message,
      logger: 'app',
      sessionId: 's',
      sequence: 1,
    );

class _ThrowingSink implements LogSink {
  int addCount = 0;

  @override
  void add(LogEvent event) {
    addCount++;
    throw StateError('sink is broken');
  }

  @override
  Future<void> flush() async => throw StateError('flush is broken');

  @override
  Future<void> close() async => throw StateError('close is broken');
}

void main() {
  group('MultiSink', () {
    test('fans one event out to every sink', () {
      final a = MemorySink();
      final b = MemorySink();
      final multi = MultiSink([a, b]);

      multi.add(_event('hello'));

      expect(a.events, hasLength(1));
      expect(b.events, hasLength(1));
    });

    test('a sink that throws on add() does not stop other sinks', () {
      final broken = _ThrowingSink();
      final healthy = MemorySink();
      final multi = MultiSink([broken, healthy]);

      multi.add(_event('one'));

      expect(healthy.events, hasLength(1));
      expect(broken.addCount, 1);
    });

    test('a broken sink is isolated after the first failure and not retried',
        () {
      final broken = _ThrowingSink();
      final healthy = MemorySink();
      final multi = MultiSink([broken, healthy]);

      multi.add(_event('one'));
      multi.add(_event('two'));
      multi.add(_event('three'));

      expect(broken.addCount, 1,
          reason: 'broken sink should be skipped after first failure');
      expect(healthy.events, hasLength(3));
    });

    test('onSinkError is invoked exactly once per broken sink', () {
      final broken = _ThrowingSink();
      final healthy = MemorySink();
      final errors = <Object>[];
      final multi = MultiSink(
        [broken, healthy],
        onSinkError: (sink, error, stack) => errors.add(error),
      );

      multi.add(_event('one'));
      multi.add(_event('two'));

      expect(errors, hasLength(1));
    });

    test('flush() and close() swallow individual sink failures', () async {
      final broken = _ThrowingSink();
      final healthy = MemorySink();
      final multi = MultiSink([broken, healthy]);

      await expectLater(multi.flush(), completes);
      await expectLater(multi.close(), completes);
    });
  });

  group('LevelFilterSink', () {
    test('drops events below the minimum level', () {
      final inner = MemorySink();
      final filtered = LevelFilterSink(inner, LogLevel.warn);

      filtered.add(_event('info', level: LogLevel.info));
      filtered.add(_event('warn', level: LogLevel.warn));
      filtered.add(_event('error', level: LogLevel.error));

      expect(inner.events.map((e) => e.message), ['warn', 'error']);
    });

    test('flush() and close() delegate to the inner sink', () async {
      final inner = MemorySink();
      final filtered = LevelFilterSink(inner, LogLevel.info);
      await expectLater(filtered.flush(), completes);
      await expectLater(filtered.close(), completes);
    });
  });

  group('MemorySink', () {
    test('bounds retained events to capacity, dropping the oldest first', () {
      final sink = MemorySink(capacity: 3);
      for (var i = 0; i < 5; i++) {
        sink.add(_event('event $i'));
      }
      expect(
          sink.events.map((e) => e.message), ['event 2', 'event 3', 'event 4']);
    });

    test('clear() empties the buffer', () {
      final sink = MemorySink();
      sink.add(_event('one'));
      sink.clear();
      expect(sink.events, isEmpty);
    });
  });
}
