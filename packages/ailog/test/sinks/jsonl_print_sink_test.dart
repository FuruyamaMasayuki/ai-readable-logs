import 'dart:async';
import 'dart:convert';

import 'package:ailog/ailog.dart';
import 'package:test/test.dart';

LogEvent _event({
  String message = 'hello',
  LogLevel level = LogLevel.info,
  Map<String, Object?> context = const {},
}) =>
    LogEvent(
      time: DateTime.utc(2026, 1, 1),
      level: level,
      message: message,
      logger: 'app',
      sessionId: 's',
      sequence: 1,
      context: context,
    );

void main() {
  group('JsonlPrintSink', () {
    test('emits one line of the exact wire format per event', () {
      final lines = <String>[];
      JsonlPrintSink(write: lines.add).add(_event());

      expect(lines, hasLength(1));
      final decoded = jsonDecode(lines.single) as Map<String, Object?>;
      expect(decoded['msg'], 'hello');
      expect(decoded['lvl'], 'info');
      expect(decoded['lg'], 'app');
    });

    test('round-trips through LogEvent.fromJson, same as the file sink', () {
      final lines = <String>[];
      JsonlPrintSink(write: lines.add)
          .add(_event(message: 'checkout', context: {'requestId': 'r1'}));

      final parsed =
          LogEvent.fromJson(jsonDecode(lines.single) as Map<String, Object?>);

      expect(parsed!.message, 'checkout');
      expect(parsed.context, {'requestId': 'r1'});
    });

    test('is parseable by DigestBuilder, the same as a JsonlFileSink line', () {
      final lines = <String>[];
      final sink = JsonlPrintSink(write: lines.add);
      sink.add(_event(message: 'a'));
      sink.add(_event(message: 'b'));

      final builder = DigestBuilder();
      for (final line in lines) {
        builder.addLine(line);
      }

      expect(builder.build().totalEvents, 2);
    });

    test('one call to write per event, no batching', () {
      final calls = <String>[];
      final sink = JsonlPrintSink(write: calls.add);

      for (var i = 0; i < 5; i++) {
        sink.add(_event(message: 'm$i'));
      }

      expect(calls, hasLength(5));
    });

    test('a throwing writer cannot break the caller', () {
      final sink = JsonlPrintSink(write: (_) => throw StateError('boom'));

      expect(() => sink.add(_event()), returnsNormally,
          reason: 'a logger must never break the program it observes');
    });

    test('defaults to print', () {
      final printed = <String>[];

      runZoned(
        () => JsonlPrintSink().add(_event()),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.add(line),
        ),
      );

      expect(printed, hasLength(1));
      expect(jsonDecode(printed.single), isA<Map>());
    });

    test('flush and close are no-ops that complete', () async {
      final sink = JsonlPrintSink(write: (_) {});
      await sink.flush();
      await sink.close();
    });

    test(
        'inside capturePrints on the same logger, its own print is not '
        're-logged', () {
      // The recipe this sink exists for combines it with ConsoleSink and
      // capturePrints in one MultiSink. Without the guard in capturePrints,
      // JsonlPrintSink's own print() would be captured and re-logged,
      // producing a second event (and a second print) for every one it
      // makes — an amplifying loop, same failure mode already guarded for
      // ConsoleSink.usingPrint().
      final memory = MemorySink();
      final logger = Logger.create(
        sink: MultiSink([memory, JsonlPrintSink(write: (_) {})]),
      );
      final printed = <String>[];

      runZoned(
        () => capturePrints(logger, () => logger.info('one event'),
            forwardToConsole: false),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.add(line),
        ),
      );

      expect(memory.events, hasLength(1),
          reason: "JsonlPrintSink's own print must not become a second "
              'event');
    });
  });
}
