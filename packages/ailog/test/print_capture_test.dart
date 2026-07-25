// print() is the subject under test here, not an accident.
// ignore_for_file: avoid_print

import 'dart:async';

import 'package:ailog/ailog.dart';
import 'package:test/test.dart';

void main() {
  group('capturePrints', () {
    test('a plain print becomes a structured event', () {
      final sink = MemorySink();
      final logger = Logger.create(sink: sink);

      capturePrints(logger, () {
        print('legacy debugging line');
      });

      final event = sink.events.single;
      expect(event.message, 'legacy debugging line');
      expect(event.logger, 'print');
      expect(event.tags, contains('print'));
      expect(event.level, LogLevel.info);
    });

    test('captured prints inherit the ambient trace', () {
      final sink = MemorySink();
      final logger = Logger.create(sink: sink);

      runWithScope(const LogScope(traceId: 'trace-1'), () {
        capturePrints(logger, () {
          print('inside the request');
        });
      });

      expect(sink.events.single.traceId, 'trace-1');
    });

    test('still forwards the raw line to the console by default', () {
      final sink = MemorySink();
      final logger = Logger.create(sink: sink);
      final consoleLines = <String>[];

      // An outer zone plays the role of the real console.
      runZoned(
        () => capturePrints(logger, () => print('hello')),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => consoleLines.add(line),
        ),
      );

      expect(consoleLines, ['hello']);
      expect(sink.events.single.message, 'hello');
    });

    test('forwardToConsole: false keeps the console quiet', () {
      final sink = MemorySink();
      final logger = Logger.create(sink: sink);
      final consoleLines = <String>[];

      runZoned(
        () => capturePrints(logger, () => print('hello'),
            forwardToConsole: false),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => consoleLines.add(line),
        ),
      );

      expect(consoleLines, isEmpty);
      expect(sink.events.single.message, 'hello');
    });

    test('a console sink printing does not feed back into the log', () {
      // The dangerous shape: the logger's own sink calls print(), inside the
      // captured zone. Without the re-entrancy guard this recurses forever.
      final memory = MemorySink();
      final printingSink = _PrintingSink(memory);
      final logger = Logger.create(sink: printingSink);
      final consoleLines = <String>[];

      runZoned(
        () =>
            capturePrints(logger, () => print('once'), forwardToConsole: false),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => consoleLines.add(line),
        ),
      );

      expect(memory.events, hasLength(1),
          reason: 'the sink\'s own print must not be captured as an event');
      expect(consoleLines, ['formatted: once'],
          reason: 'the sink\'s output still reaches the console');
    });

    test('async prints after an await are still captured', () async {
      final sink = MemorySink();
      final logger = Logger.create(sink: sink);

      await capturePrints(logger, () async {
        await Future<void>.delayed(Duration.zero);
        print('after the gap');
      });

      expect(sink.events.single.message, 'after the gap');
    });

    test('custom level and logger name', () {
      final sink = MemorySink();
      final logger = Logger.create(sink: sink);

      runZoned(
        () => capturePrints(logger, () => print('x'),
            level: LogLevel.debug, loggerName: 'legacy'),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) {}, // keep test output clean
        ),
      );

      expect(sink.events.single.level, LogLevel.debug);
      expect(sink.events.single.logger, 'legacy');
    });

    test('returns the body\'s return value', () {
      final logger = Logger.create(sink: MemorySink());
      final result = capturePrints(logger, () => 42);
      expect(result, 42);
    });
  });
}

/// A sink that prints each event — the shape of a real console sink.
class _PrintingSink implements LogSink {
  _PrintingSink(this.inner);

  final MemorySink inner;

  @override
  void add(LogEvent event) {
    inner.add(event);
    print('formatted: ${event.message}');
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}
