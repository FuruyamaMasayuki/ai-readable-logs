import 'package:ailog/ailog.dart';
import 'package:test/test.dart';

void main() {
  group('Logger', () {
    test('filters events below the minimum level', () {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink, minimumLevel: LogLevel.warn);

      logger.info('should be dropped');
      logger.warn('should be kept');

      expect(sink.events.map((e) => e.message), ['should be kept']);
    });

    test('sequence numbers are monotonic across child loggers', () {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);
      final child = logger.child('db');

      logger.info('a');
      child.info('b');
      logger.info('c');

      expect(sink.events.map((e) => e.sequence).toList(), [1, 2, 3]);
      expect(sink.events.map((e) => e.logger).toList(), ['app', 'db', 'app']);
    });

    test('startTrace + runWithScope propagates traceId to nested logs', () {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);

      final scope = logger.startTrace(context: {'requestId': 'r1'});
      runWithScope(scope, () {
        logger.info('inside trace');
      });
      logger.info('outside trace');

      expect(sink.events[0].traceId, scope.traceId);
      expect(sink.events[0].context['requestId'], 'r1');
      expect(sink.events[1].traceId, isNull);
    });

    test('span records duration and success message', () async {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);

      await logger.span('checkout', (span) async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      });

      final event = sink.events.single;
      expect(event.message, 'checkout completed');
      expect(event.durationMs, greaterThanOrEqualTo(0));
      expect(event.level, LogLevel.info);
    });

    test('span records failure with error info and rethrows', () async {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);

      await expectLater(
        () => logger.span('checkout', (span) async {
          throw StateError('boom');
        }),
        throwsStateError,
      );

      final event = sink.events.single;
      expect(event.level, LogLevel.error);
      expect(event.error, isNotNull);
      expect(event.error!.type, 'StateError');
    });

    test('error() attaches a stable fingerprint', () {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);

      try {
        throw StateError('bad state');
      } catch (e, st) {
        logger.error(e, st);
      }

      final event = sink.events.single;
      expect(event.error!.fingerprint, isNotEmpty);
    });

    test('errors carry the causal chain of preceding events in the trace', () {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);

      final scope = logger.startTrace();
      runWithScope(scope, () {
        logger.info('step 1');
        logger.info('step 2');
        try {
          throw StateError('boom');
        } catch (e, st) {
          logger.error(e, st);
        }
      });

      final errorEvent = sink.events.last;
      expect(errorEvent.chain.length, 2);
      expect(errorEvent.chain[0]['msg'], 'step 1');
      expect(errorEvent.chain[1]['msg'], 'step 2');
    });

    test('secrets are masked by default (real Redactor, not disabled)', () {
      final sink = MemorySink();
      final logger = Logger.create(sink: sink, sessionId: 's1');

      logger.info('login for alice@example.com');

      expect(sink.events.single.message, isNot(contains('alice@example.com')));
      expect(sink.events.single.message, contains('[redacted:email'));
    });

    test('context fields merge from scope and call site', () {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);

      final scope = logger.startTrace(context: {'a': 1});
      runWithScope(scope, () {
        logger.info('msg', context: {'b': 2});
      });

      expect(sink.events.single.context, {'a': 1, 'b': 2});
    });

    test(
        'logError() emits a pre-built ErrorInfo without running it through '
        'ErrorInfo.from', () {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);

      logger.logError(
        ErrorInfo(
          type: 'NSException',
          message: 'native crash',
          fingerprint: 'native-fp-1',
          frames: const ['AppDelegate.swift:42 didFinishLaunching'],
        ),
        context: {'platform': 'ios'},
      );

      final event = sink.events.single;
      expect(event.level, LogLevel.error);
      expect(event.error!.type, 'NSException');
      expect(event.error!.fingerprint, 'native-fp-1');
      expect(event.error!.frames, ['AppDelegate.swift:42 didFinishLaunching']);
      expect(event.context['platform'], 'ios');
    });

    test(
        'logError() redacts the message and frames through this logger\'s '
        'Redactor', () {
      final sink = MemorySink();
      final logger = Logger.create(sink: sink, sessionId: 's1');

      logger.logError(
        ErrorInfo(
          type: 'HttpException',
          message: 'failed for alice@example.com',
          fingerprint: 'fp',
          frames: const ['contact bob@example.com for details'],
        ),
      );

      final event = sink.events.single;
      expect(event.error!.message, isNot(contains('alice@example.com')));
      expect(event.error!.message, contains('[redacted:email'));
      expect(event.error!.frames.single, isNot(contains('bob@example.com')));
    });

    test('logError() respects an explicit level and message override', () {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);

      logger.logError(
        ErrorInfo(type: 'E', message: 'm', fingerprint: 'fp'),
        message: 'custom summary',
        level: LogLevel.fatal,
      );

      final event = sink.events.single;
      expect(event.level, LogLevel.fatal);
      expect(event.message, 'custom summary');
    });

    test('a huge message is length-bounded, not written whole', () {
      final sink = MemorySink();
      final logger = Logger.create(
        sink: sink,
        sessionId: 's1',
        limits: const SanitizerLimits(maxStringLength: 64),
      );

      logger.info('x' * 100000);

      final message = sink.events.single.message;
      expect(message.length, lessThan(200));
      expect(message, contains('chars'));
    });

    test('a huge error message and frames are length-bounded too', () {
      final sink = MemorySink();
      final logger = Logger.create(
        sink: sink,
        sessionId: 's1',
        limits: const SanitizerLimits(maxStringLength: 64),
      );

      try {
        throw StateError('y' * 100000);
      } catch (e, st) {
        logger.error(e, st);
      }

      final error = sink.events.single.error!;
      expect(error.message.length, lessThan(200));
      for (final frame in error.frames) {
        expect(frame.length, lessThan(200));
      }
    });

    test('logError() sanitizes a nested cause as well', () {
      final sink = MemorySink();
      final logger = Logger.create(sink: sink, sessionId: 's1');

      logger.logError(
        ErrorInfo(
          type: 'Outer',
          message: 'outer failure',
          fingerprint: 'fp1',
          cause: ErrorInfo(
            type: 'Inner',
            message: 'leaked alice@example.com',
            fingerprint: 'fp2',
          ),
        ),
      );

      final event = sink.events.single;
      expect(event.error!.cause!.message, isNot(contains('alice@example.com')));
    });
  });
}
