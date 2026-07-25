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

/// Stands in for the house logging facade every large codebase grows.
class _LogFacade {
  _LogFacade(this.logger);
  final Logger logger;

  void markWithoutSkip() => logger.checkpoint();
  void markWithSkip() => logger.checkpoint(skipFrames: 1);
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

    test('returns null for a non-symbolic AOT trace', () {
      // What `--obfuscate --split-debug-info` actually produces. No frame
      // here names a location, so there is nothing honest to report.
      final site = captureCallSite(
        stackTrace: StackTrace.fromString(
          'Warning: This VM has been configured to produce stack traces '
          'that violate the Dart standard.\n'
          '*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***\n'
          'pid: 1234, tid: 5678, name Dart_Initialize\n'
          'isolate_dso_base: 7f0a, vm_dso_base: 7f0a\n'
          '    #00 abs 0000561a3f51de5f '
          '_kDartIsolateSnapshotInstructions+0x51de5f\n'
          '    #01 abs 0000561a3f4a1b23 '
          '_kDartIsolateSnapshotInstructions+0x4a1b23\n',
        ),
      );
      expect(site, isNull);
    });

    test('returns null for a browser trace format Dart cannot map back', () {
      // Firefox/Safari emit `member@url:line:col` with no parentheses.
      final site = captureCallSite(
        stackTrace: StackTrace.fromString(
          'charge@http://localhost:8080/main.dart.js:9911:7\n'
          'onTap@http://localhost:8080/main.dart.js:4211:19\n',
        ),
      );
      expect(site, isNull);
    });

    test('does not report the dart2js runtime as the caller', () {
      // Under dart2js without source maps every frame points at the bundle,
      // including ailog's own plumbing and the compiler runtime. Naming one
      // of those as the call site is worse than reporting nothing, because
      // it looks correct.
      final site = captureCallSite(
        stackTrace: StackTrace.fromString(
          '    at Object.wrapException '
          '(http://localhost:8080/main.dart.js:4211:19)\n'
          '    at Logger._emit (http://localhost:8080/main.dart.js:9911:7)\n'
          '    at StackTrace_current '
          '(http://localhost:8080/main.dart.js:1002:3)\n',
        ),
      );
      expect(site, isNull);
    });

    test('still resolves a source-mapped web frame', () {
      final site = captureCallSite(
        stackTrace: StackTrace.fromString(
          '    at CartService.charge '
          '(http://localhost:8080/packages/my_app/cart.dart:42:5)\n',
        ),
      );
      expect(site, isNotNull);
      expect(site!.member, 'CartService.charge');
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

    test('checkpoint() at a raised level behaves like the leveled methods', () {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);

      logger.checkpoint(level: LogLevel.info);

      final event = sink.events.single;
      expect(event.level, LogLevel.info);
      expect(event.message, startsWith('→ '));
      expect(event.tags, contains('checkpoint'));
    });

    test('skipFrames reports the wrapper\'s caller, not the wrapper', () {
      // Every large codebase wraps its logger in a house facade. Without
      // skipFrames, every checkpoint in the app would resolve to the same
      // line inside that facade.
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);
      final facade = _LogFacade(logger);

      facade.markWithoutSkip();
      facade.markWithSkip();

      final withoutSkip = sink.events[0].message;
      final withSkip = sink.events[1].message;

      expect(withoutSkip, contains('_LogFacade.markWithoutSkip'));
      expect(withSkip, isNot(contains('_LogFacade')),
          reason: 'skipFrames should step past the facade to its caller');
    });

    test('an explicit message is never replaced by the call site', () {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);

      logger.info('a real message');

      final event = sink.events.single;
      expect(event.message, 'a real message');
      expect(event.tags, isNot(contains('checkpoint')));
    });

    test('checkpointsResolveCallSites reports whether the build supports it',
        () {
      // True under the JIT the tests run on; an app can check this at startup
      // rather than discovering blank checkpoints during an incident.
      expect(Logger.checkpointsResolveCallSites(), isTrue);
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
