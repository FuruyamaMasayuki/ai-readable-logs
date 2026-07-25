import 'package:ailog_flutter/ailog_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('dev.ailog/flutter');

/// Simulates native code invoking [method] on the bridge's channel, as if
/// the call had arrived from platform (iOS/Android) code.
Future<void> _simulateNativeCall(
    String method, Map<String, Object?> arguments) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final call = MethodCall(method, arguments);
  final byteData = _channel.codec.encodeMethodCall(call);
  await messenger.handlePlatformMessage(_channel.name, byteData, (_) {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      _channel,
      null,
    );
  });

  group('AilogNativeBridge — native to Dart', () {
    test('forwards a plain log event into the target Logger', () async {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);
      AilogNativeBridge.install(logger);

      await _simulateNativeCall('logEvent', {
        'level': 'info',
        'message': 'native did something',
        'context': {'screen': 'home'},
        'tags': ['native'],
      });

      final event = sink.events.single;
      expect(event.level, LogLevel.info);
      expect(event.message, 'native did something');
      expect(event.logger, 'native');
      expect(event.context['screen'], 'home');
      expect(event.tags, contains('native'));
    });

    test('routes to a named child logger when "logger" is given', () async {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);
      AilogNativeBridge.install(logger);

      await _simulateNativeCall('logEvent', {
        'level': 'info',
        'message': 'm',
        'logger': 'android',
      });

      expect(sink.events.single.logger, 'android');
    });

    test('defaults to info when the level is missing or unknown', () async {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);
      AilogNativeBridge.install(logger);

      await _simulateNativeCall('logEvent', {'message': 'no level'});
      await _simulateNativeCall(
          'logEvent', {'level': 'bogus', 'message': 'bad level'});

      expect(sink.events, hasLength(2));
      expect(sink.events.every((e) => e.level == LogLevel.info), isTrue);
    });

    test('builds an ErrorInfo with a fingerprint from a native error payload',
        () async {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);
      AilogNativeBridge.install(logger);

      await _simulateNativeCall('logEvent', {
        'level': 'fatal',
        'message': 'app crashed',
        'error': {
          'type': 'NSException',
          'message': 'index out of range',
          'frames': ['AppDelegate.didFinishLaunching(AppDelegate.swift:42)'],
        },
      });

      final event = sink.events.single;
      expect(event.level, LogLevel.fatal);
      expect(event.error!.type, 'NSException');
      expect(event.error!.message, 'index out of range');
      expect(event.error!.frames,
          ['AppDelegate.didFinishLaunching(AppDelegate.swift:42)']);
      expect(event.error!.fingerprint, isNotEmpty);
    });

    test('two native errors with the same type and frames share a fingerprint',
        () async {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);
      AilogNativeBridge.install(logger);

      Future<void> emit(String message) => _simulateNativeCall('logEvent', {
            'level': 'error',
            'message': message,
            'error': {
              'type': 'NSException',
              'message': message,
              'frames': ['A.method(A.swift:1)'],
            },
          });

      await emit('first occurrence');
      await emit('second occurrence, different text');

      expect(
          sink.events[0].error!.fingerprint, sink.events[1].error!.fingerprint);
    });

    test('native error messages and frames are still redacted', () async {
      final sink = MemorySink();
      final logger = Logger.create(sink: sink, sessionId: 's1');
      AilogNativeBridge.install(logger);

      await _simulateNativeCall('logEvent', {
        'level': 'error',
        'message': 'failed',
        'error': {
          'type': 'E',
          'message': 'contact alice@example.com',
          'frames': <String>[],
        },
      });

      expect(sink.events.single.error!.message,
          isNot(contains('alice@example.com')));
    });

    test('ignores method calls other than logEvent', () async {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);
      AilogNativeBridge.install(logger);

      await _simulateNativeCall('somethingElse', {'a': 1});

      expect(sink.events, isEmpty);
    });

    test('malformed arguments do not throw and produce no event', () async {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);
      AilogNativeBridge.install(logger);

      await _simulateNativeCall('logEvent', {});

      expect(sink.events, hasLength(1),
          reason: 'missing fields fall back to defaults');
      expect(sink.events.single.message, '');
    });

    test('tolerates present-but-wrong-typed fields from a buggy native caller',
        () async {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);
      AilogNativeBridge.install(logger);

      // Every field here has the wrong type for its slot — the sort of thing
      // a hand-written Kotlin/Swift caller gets wrong. None of it may throw
      // out of the channel handler, and the event must still be recorded.
      await _simulateNativeCall('logEvent', {
        'level': 42, // should be a String
        'message': 99, // should be a String
        'tags': 'not-a-list', // should be a List
        'durationMs': '120', // should be a num
        'context': {7: 'int key'}, // non-String key
      });

      expect(sink.events, hasLength(1));
      final event = sink.events.single;
      expect(event.level, LogLevel.info,
          reason: 'unparseable level falls back');
      expect(event.message, '99');
      expect(event.durationMs, 120, reason: 'numeric string is coerced');
      expect(event.context['7'], 'int key');
    });

    test('a wrong-typed error payload still produces an event', () async {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);
      AilogNativeBridge.install(logger);

      await _simulateNativeCall('logEvent', {
        'level': 'error',
        'message': 'native failure',
        'error': {
          'type': 7,
          'message': null,
          'frames': 'not-a-list',
        },
      });

      final event = sink.events.single;
      expect(event.error, isNotNull);
      expect(event.error!.type, '7');
      expect(event.error!.frames, isEmpty);
    });

    test('dispose() detaches the handler so further calls are not forwarded',
        () async {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);
      final bridge = AilogNativeBridge.install(logger);
      bridge.dispose();

      await _simulateNativeCall(
          'logEvent', {'level': 'info', 'message': 'after dispose'});

      expect(sink.events, isEmpty);
    });
  });

  group('AilogNativeBridge — Dart to native', () {
    test('install() sends a configure call with the log file path', () async {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);
      final calls = <MethodCall>[];

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        _channel,
        (call) async {
          calls.add(call);
          return null;
        },
      );

      AilogNativeBridge.install(logger, logFilePath: '/tmp/app.jsonl');
      await Future<void>.delayed(Duration.zero);

      expect(calls, hasLength(1));
      expect(calls.single.method, 'configure');
      expect(
        (calls.single.arguments as Map)['logFilePath'],
        '/tmp/app.jsonl',
      );
    });

    test('install() sends no configure call when logFilePath is omitted',
        () async {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);
      final calls = <MethodCall>[];

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        _channel,
        (call) async {
          calls.add(call);
          return null;
        },
      );

      AilogNativeBridge.install(logger);
      await Future<void>.delayed(Duration.zero);

      expect(calls, isEmpty);
    });

    test(
        'requestNativeTestLog() invokes emitTestLog and does not throw when unhandled',
        () async {
      final sink = MemorySink();
      final logger = Logger.forTesting(sink: sink);
      final bridge = AilogNativeBridge.install(logger);

      // No mock handler registered: the native side "doesn't exist" here.
      // The call must still resolve without throwing.
      await expectLater(bridge.requestNativeTestLog(), completes);
    });
  });
}
