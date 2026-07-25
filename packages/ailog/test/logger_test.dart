import 'dart:math';

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

    test('breadcrumbs below minimumLevel still reach the causal chain', () {
      // The regression this guards: breadcrumbs are naturally debug/trace,
      // so if the buffer only saw emitted events, the standard production
      // setting (minimumLevel: info) would leave every chain containing
      // nothing but info lines already visible in the file — making the
      // headline feature useless exactly where it matters.
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink, minimumLevel: LogLevel.info);

      runWithScope(logger.startTrace(), () {
        logger.debug('gateway session age=610s'); // the actual clue
        logger.trace('cache hit for key=orders');
        logger.info('POST /checkout');
        try {
          throw StateError('gateway session expired');
        } catch (e, st) {
          logger.error(e, st);
        }
      });

      // The file stays quiet: only info and the error were written.
      expect(sink.events.map((e) => e.level), [LogLevel.info, LogLevel.error]);

      // But the error carries the low-level detail that explains it.
      final chain = sink.events.last.chain;
      expect(chain.map((c) => c['msg']), [
        'gateway session age=610s',
        'cache hit for key=orders',
        'POST /checkout',
      ]);
    });

    test('breadcrumbLevel can be raised to skip buffering cheap levels', () {
      final sink = MemorySink();
      final logger = Logger.forTesting(
        sink: sink,
        minimumLevel: LogLevel.info,
        breadcrumbLevel: LogLevel.debug,
      );

      runWithScope(logger.startTrace(), () {
        logger.trace('too cheap to keep');
        logger.debug('kept as a breadcrumb');
        try {
          throw StateError('boom');
        } catch (e, st) {
          logger.error(e, st);
        }
      });

      expect(sink.events.last.chain.map((c) => c['msg']),
          ['kept as a breadcrumb']);
    });

    test('breadcrumbLevel is never allowed above minimumLevel', () {
      // A level that is neither emitted nor buffered would just vanish.
      final sink = MemorySink();
      final logger = Logger.forTesting(
        sink: sink,
        minimumLevel: LogLevel.debug,
        breadcrumbLevel: LogLevel.error,
      );

      runWithScope(logger.startTrace(), () {
        logger.debug('emitted, so it must also be a breadcrumb');
        try {
          throw StateError('boom');
        } catch (e, st) {
          logger.error(e, st);
        }
      });

      expect(sink.events.last.chain, hasLength(1));
    });

    test('causalChainLength: 0 skips buffering entirely', () {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink, minimumLevel: LogLevel.info);
      final noChain = Logger.create(
        sink: sink,
        minimumLevel: LogLevel.info,
        causalChainLength: 0,
        redactor: Redactor.disabled(),
      );
      expect(logger.isRecorded(LogLevel.trace), isTrue);
      expect(noChain.isRecorded(LogLevel.trace), isFalse,
          reason: 'with chains off there is no reason to keep breadcrumbs');
    });

    test('sequence numbers have no gaps despite buffered-only events', () {
      // Gaps would read like dropped lines to anyone reading the file.
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink, minimumLevel: LogLevel.info);

      logger.debug('breadcrumb');
      logger.info('first');
      logger.trace('breadcrumb');
      logger.info('second');
      logger.info('third');

      expect(sink.events.map((e) => e.sequence), [1, 2, 3]);
    });

    test('isEnabled and isRecorded distinguish emitted from buffered', () {
      final logger = Logger.forTesting(minimumLevel: LogLevel.info);

      expect(logger.isEnabled(LogLevel.debug), isFalse);
      expect(logger.isEnabled(LogLevel.info), isTrue);
      expect(logger.isRecorded(LogLevel.debug), isTrue,
          reason: 'still kept as a breadcrumb');
      expect(logger.minimumLevel, LogLevel.info);
    });

    test('baseContext is attached to every event without a scope', () {
      // Unlike a trace scope this needs no runWithScope, so it also covers
      // timers, isolates and anything logged before a zone is entered.
      final sink = MemorySink();
      final logger = Logger.create(
        sink: sink,
        redactor: Redactor.disabled(),
        baseContext: {'appVersion': '1.4.2', 'env': 'prod'},
      );

      logger.info('outside any scope');
      logger.child('db').info('from a child logger');

      for (final event in sink.events) {
        expect(event.context['appVersion'], '1.4.2');
        expect(event.context['env'], 'prod');
      }
    });

    test('scope and call-site fields win over baseContext', () {
      final sink = MemorySink();
      final logger = Logger.create(
        sink: sink,
        redactor: Redactor.disabled(),
        baseContext: {'env': 'prod', 'tier': 'base'},
      );

      runWithScope(logger.startTrace(context: {'tier': 'scope'}), () {
        logger.info('a');
        logger.info('b', context: {'tier': 'call-site'});
      });

      expect(sink.events[0].context['tier'], 'scope');
      expect(sink.events[1].context['tier'], 'call-site');
      expect(sink.events[1].context['env'], 'prod');
    });

    test('includePlatformContext records the environment once per event', () {
      final sink = MemorySink();
      final logger = Logger.create(
        sink: sink,
        redactor: Redactor.disabled(),
        includePlatformContext: true,
      );

      logger.info('hello');

      // "Reproduces only on Linux with Dart 3.9" is a conclusion an analyst
      // can only reach if the log says which platform produced it.
      expect(sink.events.single.context['os'], isNotNull);
      expect(sink.events.single.context['dart'], isNotNull);
    });

    test('an injected clock makes output deterministic', () {
      final sink = MemorySink();
      var tick = DateTime.utc(2026, 1, 1);
      final logger = Logger.forTesting(
        sink: sink,
        clock: () => tick,
        idGenerator: IdGenerator(random: Random(1)),
      );

      logger.info('first');
      tick = tick.add(const Duration(seconds: 5));
      logger.info('second');

      expect(sink.events[0].time, DateTime.utc(2026, 1, 1));
      expect(sink.events[1].time, DateTime.utc(2026, 1, 1, 0, 0, 5));
    });

    test('an injected IdGenerator makes trace ids reproducible', () {
      Logger build() => Logger.forTesting(
            sink: MemorySink(),
            idGenerator: IdGenerator(random: Random(42)),
          );

      expect(build().startTrace().traceId, build().startTrace().traceId);
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

  group('startSpan (manual form)', () {
    test('the completion event carries the trace and span ids', () {
      final sink = MemorySink();
      final logger = Logger.create(sink: sink);

      logger.startSpan('upload').succeed();

      final event = sink.events.single;
      expect(event.message, 'upload completed');
      expect(event.traceId, isNotNull);
      expect(event.spanId, isNotNull);
      expect(event.durationMs, isNotNull);
    });

    test('does NOT install its scope — intervening logs are unattributed', () {
      // Documented, deliberate, and a genuine trap: startSpan only creates
      // the span. This test pins the behaviour so the docs stay true, and so
      // that changing it is a conscious decision rather than an accident.
      final sink = MemorySink();
      final logger = Logger.create(sink: sink);

      final span = logger.startSpan('upload');
      logger.info('between start and finish');
      span.succeed();

      final between = sink.events
          .firstWhere((e) => e.message == 'between start and finish');
      expect(between.traceId, isNull,
          reason: 'use runWithScope(span.scope, ...) or logger.span() instead');
      expect(between.spanId, isNull);
    });

    test('runWithScope(span.scope, ...) attributes them correctly', () {
      final sink = MemorySink();
      final logger = Logger.create(sink: sink);

      final span = logger.startSpan('upload');
      runWithScope(span.scope, () => logger.info('inside'));
      span.succeed();

      final inside = sink.events.firstWhere((e) => e.message == 'inside');
      final done =
          sink.events.firstWhere((e) => e.message == 'upload completed');
      expect(inside.traceId, done.traceId);
      expect(inside.spanId, done.spanId);
    });

    test('finishing twice emits only once', () {
      final sink = MemorySink();
      final logger = Logger.create(sink: sink);

      final span = logger.startSpan('upload')
        ..succeed()
        ..succeed();
      span.fail(StateError('too late'));

      expect(sink.events, hasLength(1));
    });

    test('fail() records the error, duration and causal chain', () {
      final sink = MemorySink();
      final logger = Logger.create(sink: sink);

      final span = logger.startSpan('upload');
      span.fail(StateError('boom'), StackTrace.current);

      final event = sink.events.single;
      expect(event.level, LogLevel.error);
      expect(event.message, 'upload failed');
      expect(event.error!.type, 'StateError');
      expect(event.durationMs, isNotNull);
    });
  });

  group('interaction', () {
    test('records the intent with a marker and a tag', () {
      final sink = MemorySink();
      Logger.create(sink: sink)
          .interaction('checkout_pressed', context: {'items': 3});

      final event = sink.events.single;
      expect(event.message, '▸ checkout_pressed');
      expect(event.level, LogLevel.trace);
      expect(event.tags, contains('interaction'));
      expect(event.context['items'], 3);
    });

    test('stays out of a production file but lands in the causal chain', () {
      // The whole design: user actions are noise in the file and decisive in
      // the chain. `minimumLevel: info` is the realistic production setting.
      final sink = MemorySink();
      final logger = Logger.create(sink: sink, minimumLevel: LogLevel.info);

      runWithScope(logger.startTrace(), () {
        logger.interaction('view_cart_pressed');
        logger.interaction('checkout_pressed');
        logger.error(StateError('declined'), StackTrace.current);
      });

      expect(sink.events, hasLength(1),
          reason: 'interactions must not fill the file');
      expect(
        sink.events.single.chain.map((c) => c['msg']),
        ['▸ view_cart_pressed', '▸ checkout_pressed'],
      );
    });

    test('caller tags are kept alongside the interaction tag', () {
      final sink = MemorySink();
      Logger.create(sink: sink).interaction('tap', tags: ['onboarding']);

      expect(
          sink.events.single.tags, containsAll(['interaction', 'onboarding']));
    });

    test('the level is raisable for apps that want them written', () {
      final sink = MemorySink();
      Logger.create(sink: sink, minimumLevel: LogLevel.info)
          .interaction('tap', level: LogLevel.info);

      expect(sink.events, hasLength(1));
    });

    test('context is redacted like any other event', () {
      final sink = MemorySink();
      Logger.create(sink: sink, redactor: Redactor(salt: 'fixed'))
          .interaction('signup', context: {'email': 'a@example.com'});

      expect(sink.events.single.context['email'], contains('[redacted:email'));
    });
  });
}
