// print() is deliberate here — it is what these tests are about.
// ignore_for_file: avoid_print

import 'dart:async';

import 'package:ailog/ailog.dart';
import 'package:test/test.dart';

LogEvent _event({
  String message = 'hello',
  LogLevel level = LogLevel.info,
}) =>
    LogEvent(
      time: DateTime.utc(2026),
      level: level,
      message: message,
      logger: 'app',
      sessionId: 's',
      sequence: 1,
    );

void main() {
  group('ConsoleSink', () {
    test('a custom write receives the formatted line', () {
      final lines = <String>[];
      ConsoleSink(write: lines.add, useColor: false).add(_event());

      expect(lines, hasLength(1));
      expect(lines.single, contains('hello'));
    });

    test('usingPrint emits through print', () {
      final printed = <String>[];

      runZoned(
        () => ConsoleSink.usingPrint().add(_event(message: 'via print')),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.add(line),
        ),
      );

      expect(printed, hasLength(1));
      expect(printed.single, contains('via print'));
    });

    test('usingPrint leaves colour off by default', () {
      // Flutter's console, logcat and the Xcode console all render ANSI
      // escapes literally, so colour there is worse than no colour.
      final printed = <String>[];

      runZoned(
        () => ConsoleSink.usingPrint().add(_event(level: LogLevel.error)),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.add(line),
        ),
      );

      expect(printed.single, isNot(contains('\x1B[')));
    });

    test('a throwing writer cannot break the caller', () {
      final sink = ConsoleSink(write: (_) => throw StateError('boom'));

      expect(() => sink.add(_event()), returnsNormally,
          reason: 'a logger must never break the program it observes');
    });

    test('print-based console output inside capturePrints is not re-logged',
        () {
      // The loop-shaped case: the sink prints, and print is being captured.
      final memory = MemorySink();
      final logger = Logger.create(
        sink: MultiSink([memory, ConsoleSink.usingPrint()]),
      );
      final printed = <String>[];

      runZoned(
        () => capturePrints(logger, () => print('one line'),
            forwardToConsole: false),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.add(line),
        ),
      );

      expect(memory.events, hasLength(1),
          reason: 'the console sink\'s own print must not become an event');
      expect(printed, hasLength(1));
      expect(printed.single, contains('one line'));
    });
  });
}
