import 'package:ailog/ailog.dart';
import 'package:test/test.dart';

/// A helper at a known location, used to prove the captured call site points
/// at the *caller's* code rather than somewhere inside ailog.
void _logFromHelper(Logger logger) => logger.checkpoint();

class _Service {
  _Service(this.logger);
  final Logger logger;

  void doWork() => logger.checkpoint();
}

void main() {
  group('captureCallSite', () {
    test('resolves a frame outside ailog', () {
      final site = captureCallSite();
      expect(site, isNotNull);
      expect(site!.location, contains('call_site_test.dart'));
    });

    test('render() prefixes with an arrow marker', () {
      const site = CallSite(location: 'a.dart:1', member: 'Foo.bar');
      expect(site.render(), '→ a.dart:1 Foo.bar');
    });

    test('render() omits the member when empty', () {
      const site = CallSite(location: 'a.dart:1', member: '');
      expect(site.render(), '→ a.dart:1');
    });

    test('returns null for an unparseable stack trace', () {
      final site = captureCallSite(
        stackTrace: StackTrace.fromString('not a stack trace at all'),
      );
      expect(site, isNull);
    });

    test('skipFrames walks further down the stack', () {
      final direct = captureCallSite();
      final skipped = captureCallSite(skipFrames: 1);
      // Both resolve within the test harness, but to different frames.
      expect(direct, isNotNull);
      expect(skipped?.location, isNot(direct!.location));
    });
  });

  group('Logger checkpoint', () {
    test('synthesizes a message from the call site', () {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);

      logger.checkpoint();

      final event = sink.events.single;
      expect(event.message, startsWith('→ '));
      expect(event.message, contains('call_site_test.dart'));
      expect(event.level, LogLevel.trace);
    });

    test('tags the event as a checkpoint', () {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);

      logger.checkpoint();

      expect(sink.events.single.tags, contains('checkpoint'));
    });

    test('points at the caller, not at ailog internals', () {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);

      _logFromHelper(logger);

      final message = sink.events.single.message;
      expect(message, contains('call_site_test.dart'));
      expect(message, isNot(contains('package:ailog/')));
    });

    test('records the enclosing member name', () {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);

      _Service(logger).doWork();

      expect(sink.events.single.message, contains('_Service.doWork'));
    });

    test('two checkpoints in different places produce different messages', () {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);

      logger.checkpoint();
      logger.checkpoint();

      expect(sink.events[0].message, isNot(sink.events[1].message));
    });

    test('accepts a custom level', () {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);

      logger.checkpoint(level: LogLevel.info);

      expect(sink.events.single.level, LogLevel.info);
    });

    test('merges call-site context and tags', () {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);

      logger.checkpoint(context: {'orderId': 44}, tags: ['checkout']);

      final event = sink.events.single;
      expect(event.context['orderId'], 44);
      expect(event.tags, containsAll(['checkout', 'checkpoint']));
    });

    test('is filtered out by minimumLevel without capturing a stack', () {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink, minimumLevel: LogLevel.info);

      logger.checkpoint(); // defaults to trace, below the threshold

      expect(sink.events, isEmpty);
    });

    test('a null message on a leveled method behaves as a checkpoint', () {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);

      logger.info(null);

      final event = sink.events.single;
      expect(event.level, LogLevel.info);
      expect(event.message, startsWith('→ '));
      expect(event.tags, contains('checkpoint'));
    });

    test('an explicit message is never replaced by the call site', () {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);

      logger.info('a real message');

      final event = sink.events.single;
      expect(event.message, 'a real message');
      expect(event.tags, isNot(contains('checkpoint')));
    });

    test('checkpoints participate in the causal chain like any event', () {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);

      final scope = logger.startTrace();
      runWithScope(scope, () {
        logger.checkpoint();
        try {
          throw StateError('boom');
        } catch (e, st) {
          logger.error(e, st);
        }
      });

      final errorEvent = sink.events.last;
      expect(errorEvent.chain, hasLength(1));
      expect(errorEvent.chain.single['msg'], startsWith('→ '));
    });
  });
}
