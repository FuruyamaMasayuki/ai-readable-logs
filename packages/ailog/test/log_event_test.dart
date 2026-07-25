import 'package:ailog/ailog.dart';
import 'package:test/test.dart';

void main() {
  group('ErrorInfo', () {
    test('toJson/fromJson round-trips including a nested cause', () {
      final info = ErrorInfo(
        type: 'HttpException',
        message: 'connection refused',
        fingerprint: 'abc123',
        frames: const ['a.dart:1 main'],
        cause: ErrorInfo(
          type: 'SocketException',
          message: 'os error',
          fingerprint: 'def456',
        ),
      );

      final restored = ErrorInfo.fromJson(info.toJson())!;

      expect(restored.type, info.type);
      expect(restored.message, info.message);
      expect(restored.fingerprint, info.fingerprint);
      expect(restored.frames, info.frames);
      expect(restored.cause!.type, 'SocketException');
      expect(restored.cause!.fingerprint, 'def456');
    });

    test('fromJson returns null for non-map input', () {
      expect(ErrorInfo.fromJson(null), isNull);
      expect(ErrorInfo.fromJson('not a map'), isNull);
    });

    test('fromJson fills in defaults for missing fields', () {
      final info = ErrorInfo.fromJson(<String, Object?>{})!;
      expect(info.type, 'Error');
      expect(info.message, '');
      expect(info.fingerprint, '');
      expect(info.frames, isEmpty);
      expect(info.cause, isNull);
    });

    test('ErrorInfo.from() puts application frames before SDK frames', () {
      final stack = StackTrace.fromString(
        '#0      _CustomZone.run (dart:async/zone.dart:1000:19)\n'
        '#1      Cart.checkout (package:app/checkout/cart.dart:42:5)\n'
        '#2      main (package:app/main.dart:10:3)\n',
      );
      final info = ErrorInfo.from(StateError('boom'), stack);

      expect(info.frames.first, contains('Cart.checkout'));
      expect(info.frames[1], contains('main'));
      expect(info.frames.last, contains('_CustomZone.run'));
    });

    test('ErrorInfo.from() respects maxFrames', () {
      final lines = List.generate(
        20,
        (i) => '#$i      f$i (package:app/a.dart:$i:1)',
      ).join('\n');
      final info = ErrorInfo.from(
        StateError('boom'),
        StackTrace.fromString(lines),
        maxFrames: 3,
      );
      expect(info.frames, hasLength(3));
    });

    test('ErrorInfo.from() applies sanitizeText to the message', () {
      final info = ErrorInfo.from(
        StateError('contact alice@example.com'),
        null,
        sanitizeText: (text) =>
            text.replaceAll('alice@example.com', '[redacted]'),
      );
      expect(info.message, contains('[redacted]'));
      expect(info.message, isNot(contains('alice@example.com')));
    });

    test(
        'ErrorInfo.from() derives a fingerprint consistent with errorFingerprint',
        () {
      final stack = StackTrace.fromString(
        '#0      Cart.checkout (package:app/checkout/cart.dart:42:5)\n',
      );
      final info = ErrorInfo.from(StateError('boom'), stack);
      final expected = errorFingerprint(
        errorType: 'StateError',
        message: 'Bad state: boom',
        stackTrace: stack,
      );
      expect(info.fingerprint, expected);
    });
  });

  group('LogEvent', () {
    LogEvent fullEvent() => LogEvent(
          time: DateTime.utc(2026, 1, 1, 12, 0, 0),
          level: LogLevel.error,
          message: 'payment failed',
          logger: 'payments',
          sessionId: 'sess-1',
          sequence: 7,
          traceId: 'trace-1',
          spanId: 'span-1',
          parentSpanId: 'span-0',
          context: {'orderId': 44},
          tags: const ['checkout'],
          error: ErrorInfo(type: 'E', message: 'm', fingerprint: 'fp'),
          durationMs: 120,
          chain: const [
            {'dt': -50, 'lvl': 'info', 'msg': 'step'},
          ],
        );

    test('toJson/fromJson round-trips every field', () {
      final event = fullEvent();
      final restored = LogEvent.fromJson(event.toJson())!;

      expect(restored.level, event.level);
      expect(restored.message, event.message);
      expect(restored.logger, event.logger);
      expect(restored.sessionId, event.sessionId);
      expect(restored.sequence, event.sequence);
      expect(restored.traceId, event.traceId);
      expect(restored.spanId, event.spanId);
      expect(restored.parentSpanId, event.parentSpanId);
      expect(restored.context, event.context);
      expect(restored.tags, event.tags);
      expect(restored.error!.fingerprint, event.error!.fingerprint);
      expect(restored.durationMs, event.durationMs);
      expect(restored.chain, event.chain);
      expect(restored.time.toIso8601String(), event.time.toIso8601String());
    });

    test('toJson omits null/empty optional fields', () {
      final event = LogEvent(
        time: DateTime.utc(2026),
        level: LogLevel.info,
        message: 'hi',
        logger: 'app',
        sessionId: 's',
        sequence: 1,
      );
      final json = event.toJson();
      expect(json.containsKey('tr'), isFalse);
      expect(json.containsKey('sp'), isFalse);
      expect(json.containsKey('psp'), isFalse);
      expect(json.containsKey('dur'), isFalse);
      expect(json.containsKey('tags'), isFalse);
      expect(json.containsKey('ctx'), isFalse);
      expect(json.containsKey('err'), isFalse);
      expect(json.containsKey('chain'), isFalse);
    });

    test('fromJson returns null for an unparseable level', () {
      final json = fullEvent().toJson();
      json['lvl'] = 'not-a-level';
      expect(LogEvent.fromJson(json), isNull);
    });

    test('fromJson returns null for an unparseable timestamp', () {
      final json = fullEvent().toJson();
      json['ts'] = 'not-a-date';
      expect(LogEvent.fromJson(json), isNull);
    });

    test('fromJson skips a schema header line (missing lvl/ts)', () {
      expect(
        LogEvent.fromJson({'_hdr': true, 'schema': 1}),
        isNull,
      );
    });

    test(
        'toChainEntry renders a negative millisecond offset relative to a later time',
        () {
      final earlier = LogEvent(
        time: DateTime.utc(2026, 1, 1, 0, 0, 0),
        level: LogLevel.info,
        message: 'step one',
        logger: 'app',
        sessionId: 's',
        sequence: 1,
      );
      final later = DateTime.utc(2026, 1, 1, 0, 0, 0, 300);

      final entry = earlier.toChainEntry(later);
      expect(entry['dt'], -300);
      expect(entry['lvl'], 'info');
      expect(entry['msg'], 'step one');
      expect(entry.containsKey('lg'), isFalse,
          reason: 'default logger name app is omitted');
    });

    test('toChainEntry includes the logger name when it is not "app"', () {
      final event = LogEvent(
        time: DateTime.utc(2026),
        level: LogLevel.info,
        message: 'query',
        logger: 'db',
        sessionId: 's',
        sequence: 1,
      );
      final entry = event.toChainEntry(DateTime.utc(2026));
      expect(entry['lg'], 'db');
    });

    test('toChainEntry includes context only when non-empty', () {
      final event = LogEvent(
        time: DateTime.utc(2026),
        level: LogLevel.info,
        message: 'm',
        logger: 'app',
        sessionId: 's',
        sequence: 1,
        context: {'a': 1},
      );
      final entry = event.toChainEntry(DateTime.utc(2026));
      expect(entry['ctx'], {'a': 1});
    });
  });

  group('schemaLegend / aiLogSchemaVersion', () {
    test('legend documents every short key used by LogEvent.toJson', () {
      final legend = schemaLegend();
      const expectedKeys = [
        'ts', 'lvl', 'msg', 'lg', 'ses', 'tr', 'sp', 'psp', 'seq', 'dur',
        'tags', 'ctx', 'err', 'chain', //
      ];
      for (final key in expectedKeys) {
        expect(legend.containsKey(key), isTrue,
            reason: 'missing legend entry for "$key"');
      }
    });

    test('a fully populated event emits no key the legend omits', () {
      // The file's claim is that it explains itself. Enumerating expected
      // keys by hand (above) cannot catch a *new* key added to toJson, so
      // this checks the real direction: everything emitted is documented.
      final event = LogEvent(
        time: DateTime.utc(2026),
        level: LogLevel.error,
        message: 'm',
        logger: 'app',
        sessionId: 's',
        sequence: 1,
        traceId: 't',
        spanId: 'sp',
        parentSpanId: 'psp',
        durationMs: 5,
        tags: const ['x'],
        context: const {'k': 1},
        error: ErrorInfo(type: 'E', message: 'm', fingerprint: 'f'),
        chain: const [
          {'dt': -1, 'lvl': 'info', 'msg': 'before'},
        ],
      );

      expect(event.toJson().keys, everyElement(isIn(schemaLegend().keys)));
    });

    test('non-key conventions are marked so they cannot be read as fields', () {
      // Redaction is a convention applying to *any* field, not a key. Listed
      // bare among the keys, a reader could go looking for an event field
      // called `redacted` that never exists.
      final conventions =
          schemaLegend().keys.where((k) => k.startsWith('_convention:'));

      expect(conventions, contains('_convention:redacted'));
      expect(schemaLegend().containsKey('redacted'), isFalse);
    });

    test('aiLogSchemaVersion is a positive integer', () {
      expect(aiLogSchemaVersion, greaterThan(0));
    });
  });
}
