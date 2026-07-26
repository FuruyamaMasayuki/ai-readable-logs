// End-to-end: a real app process serving a real VM Service, and the real CLI
// pulling from it over a real WebSocket.
//
// Everything about this feature that can break lives in the transport — the
// ws:// URI derivation, the JSON-RPC framing, the isolate id, the cursor
// round trip. A test with a fake client would exercise none of it.
@Timeout(Duration(seconds: 90))
library;

import 'dart:convert';
import 'dart:io';

import 'package:ailog/src/log_event.dart';
import 'package:test/test.dart';

void main() {
  group('debug sync over the VM Service', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('ailog_sync'));
    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    /// Starts the app under `--observe` and returns it with its service URI.
    Future<(Process, Uri)> startApp({int capacity = 1000}) async {
      final process = await Process.start(
        Platform.resolvedExecutable,
        [
          'run',
          '--observe=0/127.0.0.1',
          '--no-serve-devtools',
          'test/regression/_debug_sync_app.dart',
          '$capacity',
        ],
        environment: {'DART_VM_OPTIONS': ''},
      );

      final lines = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asBroadcastStream();

      Uri? serviceUri;
      var ready = false;
      await for (final line in lines) {
        final match =
            RegExp(r'(http://127\.0\.0\.1:\d+/[^\s]*)').firstMatch(line);
        if (match != null) serviceUri = Uri.parse(match.group(1)!);
        if (line.contains('AILOG_SYNC_READY')) {
          expect(line, contains('registered=true'),
              reason: 'a JIT run must register the extension');
          ready = true;
        }
        if (serviceUri != null && ready) break;
      }

      expect(serviceUri, isNotNull, reason: 'no VM Service URI was printed');
      return (process, serviceUri!);
    }

    Future<ProcessResult> runSync(List<String> args) => Process.run(
          Platform.resolvedExecutable,
          ['run', 'bin/ailog_sync.dart', ...args],
        );

    List<LogEvent> readEvents(String path) => [
          for (final line in File(path).readAsLinesSync())
            if (line.trim().isNotEmpty)
              LogEvent.fromJson(jsonDecode(line) as Map<String, Object?>)!
        ];

    test('a single poll pulls what the app has logged so far', () async {
      final (process, uri) = await startApp();
      addTearDown(process.kill);

      // Let a few events accumulate before asking.
      await Future<void>.delayed(const Duration(milliseconds: 600));

      final output = '${temp.path}/once.jsonl';
      final result = await runSync(['--vm-service', '$uri', '-o', output]);

      expect(result.exitCode, 0, reason: '${result.stderr}');
      final events = readEvents(output);
      expect(events, isNotEmpty);
      expect(events.first.message, 'event 0',
          reason: 'a cursor of 0 must mean "everything"');
      // Ordering and completeness: seq is dense from 1.
      expect(
        [for (final e in events) e.sequence],
        List.generate(events.length, (i) => i + 1),
      );
    });

    test('--watch keeps appending, without re-sending what it already has',
        () async {
      final (process, uri) = await startApp();
      addTearDown(process.kill);

      final output = '${temp.path}/watch.jsonl';
      final result = await runSync([
        '--vm-service', '$uri', '-o', output, //
        '--watch', '--interval', '0.2',
      ]).timeout(const Duration(seconds: 60));

      expect(result.exitCode, 0, reason: '${result.stderr}');
      final events = readEvents(output);

      // The app emits 40 events at 50ms; a 200ms poll spans several, so this
      // only passes if the cursor advances correctly across polls.
      expect(events, hasLength(40));
      expect(
        [for (final e in events) e.sequence],
        List.generate(40, (i) => i + 1),
        reason: 'no duplicates and no gaps across polls',
      );
      expect(result.stderr, contains('40 events'));
      // The app exiting is a clean end to a --watch run, not an error: you
      // stop `flutter run` and expect a usable file, not a stack trace.
      expect(result.stderr, contains('the app disconnected'));
    });

    test('a buffer that rolls over reports the loss instead of hiding it',
        () async {
      // Capacity far below the 40 events emitted, so events fall out between
      // polls no matter how fast we ask.
      final (process, uri) = await startApp(capacity: 5);
      addTearDown(process.kill);

      final output = '${temp.path}/lossy.jsonl';
      final result = await runSync([
        '--vm-service', '$uri', '-o', output, //
        '--watch', '--interval', '1',
      ]).timeout(const Duration(seconds: 60));

      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        result.stderr,
        contains('rolled out of the app'),
        reason: 'silent loss is the failure mode this whole package exists '
            'to avoid; it must be said out loud',
      );
      // What did survive is still valid, parseable JSONL.
      expect(readEvents(output), isNotEmpty);
    });

    test('a missing extension is reported as such, not as an empty log',
        () async {
      // A plain `dart run --observe` with no installDebugSync call: the VM
      // Service is there, the extension is not.
      final script = File('${temp.path}/bare.dart')..writeAsStringSync('''
import 'dart:io';
Future<void> main() async {
  await Future<void>.delayed(const Duration(seconds: 20));
  exit(0);
}
''');
      final process = await Process.start(
        Platform.resolvedExecutable,
        ['run', '--observe=0/127.0.0.1', '--no-serve-devtools', script.path],
      );
      addTearDown(process.kill);

      Uri? uri;
      await for (final line in process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        final match =
            RegExp(r'(http://127\.0\.0\.1:\d+/[^\s]*)').firstMatch(line);
        if (match != null) {
          uri = Uri.parse(match.group(1)!);
          break;
        }
      }
      expect(uri, isNotNull);

      final result = await runSync(
          ['--vm-service', '$uri', '-o', '${temp.path}/none.jsonl']);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('installDebugSync'),
          reason: 'the message must name the fix, not just the symptom');
    });

    test('an unreachable VM Service fails with a usable message', () async {
      final result = await runSync([
        '--vm-service', 'http://127.0.0.1:1/nope=/', //
        '-o', '${temp.path}/dead.jsonl',
      ]);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('is the app running?'));
    });
  });
}
