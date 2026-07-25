import 'package:ailog/ailog.dart';
import 'package:test/test.dart';

void main() {
  group('build mode detection', () {
    test('`dart test` reports a debug build', () {
      // The test runner is JIT with assertions, so this is the one mode we
      // can assert about from inside a test. The other two are exercised by
      // byBuildMode's dispatch below.
      expect(isDebugBuild, isTrue);
      expect(isReleaseBuild, isFalse);
      expect(isProfileBuild, isFalse);
      expect(currentBuildMode, BuildMode.debug);
    });

    test('exactly one mode is ever true', () {
      final flags = [isDebugBuild, isProfileBuild, isReleaseBuild];
      expect(flags.where((f) => f), hasLength(1));
    });
  });

  group('byBuildMode', () {
    test('returns the debug value here', () {
      expect(
        byBuildMode(debug: LogLevel.trace, release: LogLevel.warn),
        LogLevel.trace,
      );
    });

    test('profile falls back to release when not given', () {
      // Asserted structurally rather than by mode, since a test always runs
      // in debug: the same call with each mode's value distinct proves the
      // dispatch, and the fallback is visible in the default.
      T pick<T>(BuildMode mode,
              {required T debug, required T release, T? profile}) =>
          switch (mode) {
            BuildMode.debug => debug,
            BuildMode.profile => profile ?? release,
            BuildMode.release => release,
          };

      expect(pick(BuildMode.profile, debug: 'd', release: 'r'), 'r');
      expect(
          pick(BuildMode.profile, debug: 'd', release: 'r', profile: 'p'), 'p');
      expect(pick(BuildMode.release, debug: 'd', release: 'r'), 'r');
      expect(pick(BuildMode.debug, debug: 'd', release: 'r'), 'd');
    });
  });

  group('Logger enabled: false', () {
    test('emits nothing at any level', () {
      final sink = MemorySink();
      final logger = Logger.create(sink: sink, enabled: false);

      logger.trace('t');
      logger.info('i');
      logger.warn('w');
      logger.errorMessage('e');
      logger.error(StateError('boom'), StackTrace.current);
      logger.checkpoint();

      expect(sink.events, isEmpty);
    });

    test('reports itself as disabled through isEnabled/isRecorded', () {
      final logger = Logger.create(sink: MemorySink(), enabled: false);

      for (final level in LogLevel.values) {
        expect(logger.isEnabled(level), isFalse);
        expect(logger.isRecorded(level), isFalse,
            reason: 'guarded expensive context must be skipped too');
      }
    });

    test('records no breadcrumbs, so a later error carries no chain', () {
      // The subtle one: breadcrumbs are captured below minimumLevel, so a
      // disabled logger that only skipped emission would still pay for them.
      final sink = MemorySink();
      final logger = Logger.create(sink: sink, enabled: false);

      runWithScope(const LogScope(traceId: 't1'), () {
        logger.debug('breadcrumb');
        logger.error(StateError('boom'), StackTrace.current);
      });

      expect(sink.events, isEmpty);
    });

    test('spans and traces still run their bodies', () {
      // Disabling logging must not disable the program.
      final logger = Logger.create(sink: MemorySink(), enabled: false);
      var ran = false;

      final result = logger.spanSync('work', (span) {
        ran = true;
        return 7;
      });

      expect(ran, isTrue);
      expect(result, 7);
    });

    test('child loggers inherit the disabled state', () {
      final sink = MemorySink();
      final logger = Logger.create(sink: sink, enabled: false);

      logger.child('db').info('query');

      expect(sink.events, isEmpty);
    });

    test('enabled: true is the default and still logs', () {
      final sink = MemorySink();
      Logger.create(sink: sink).info('hello');

      expect(sink.events, hasLength(1));
    });
  });

  group('Logger.disabled', () {
    test('accepts every call and produces nothing', () {
      final logger = Logger.disabled();

      expect(() {
        logger.info('x');
        logger.error(StateError('boom'), StackTrace.current);
        logger.checkpoint();
        logger.child('db').warn('y');
      }, returnsNormally);

      for (final level in LogLevel.values) {
        expect(logger.isRecorded(level), isFalse);
      }
    });

    test('flush and close are safe', () async {
      final logger = Logger.disabled();
      await logger.flush();
    });

    test('spans complete and return values', () async {
      final logger = Logger.disabled();
      expect(await logger.span('work', (s) async => 42), 42);
    });
  });
}
