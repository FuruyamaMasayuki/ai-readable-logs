import 'dart:convert';

import 'package:ailog/ailog.dart';
import 'package:ailog/src/debug_sync.dart';
import 'package:ailog/src/sync_cli.dart';
import 'package:ailog/src/vm_service_client.dart';
import 'package:test/test.dart';

void main() {
  group('SyncCliOptions.parse', () {
    test('no arguments reads stdin and writes the default path', () {
      final options = SyncCliOptions.parse([])!;

      expect(options.source, SyncSource.stdin);
      expect(options.outputPath, '.ailog/synced.jsonl');
      expect(options.vmServiceUri, isNull);
      expect(options.follow, isFalse);
    });

    test('--vm-service selects the VM Service source', () {
      final options = SyncCliOptions.parse(
          ['--vm-service', 'http://127.0.0.1:8181/abc=/', '-o', 'a.jsonl'])!;

      expect(options.source, SyncSource.vmService);
      expect(options.vmServiceUri.toString(), 'http://127.0.0.1:8181/abc=/');
      expect(options.outputPath, 'a.jsonl');
    });

    test('--interval accepts fractional seconds', () {
      expect(SyncCliOptions.parse(['--interval', '0.25'])!.interval,
          const Duration(milliseconds: 250));
    });

    test('malformed arguments return null rather than a default', () {
      // Each of these would otherwise silently do something other than what
      // was asked — the worst outcome for a tool you leave running.
      expect(SyncCliOptions.parse(['--vm-service']), isNull);
      expect(SyncCliOptions.parse(['--vm-service', 'not a uri']), isNull);
      expect(SyncCliOptions.parse(['--interval', 'soon']), isNull);
      expect(SyncCliOptions.parse(['--interval', '0']), isNull);
      expect(SyncCliOptions.parse(['--interval', '-1']), isNull);
      expect(SyncCliOptions.parse(['-o']), isNull);
      expect(SyncCliOptions.parse(['--nope']), isNull);
      expect(SyncCliOptions.parse(['stray.jsonl']), isNull);
    });

    test('-h is recognized even alongside other flags', () {
      expect(SyncCliOptions.parse(['--watch', '-h'])!.showHelp, isTrue);
    });
  });

  group('extractJsonlLine', () {
    LogEvent sample() {
      final sink = MemorySink();
      Logger.forTesting(sink: sink).info('hello', context: {'a': 1});
      return sink.events.single;
    }

    test('accepts a bare JSONL line', () {
      final line = jsonEncode(sample().toJson());
      expect(extractJsonlLine(line), line);
    });

    test('strips the logcat prefix Android adds', () {
      final line = jsonEncode(sample().toJson());
      expect(extractJsonlLine('I/flutter ( 6666): $line'), line);
    });

    test('accepts the schema header line', () {
      const header = '{"_hdr":true,"schema":1}';
      expect(extractJsonlLine(header), header);
    });

    test('rejects ordinary run output', () {
      expect(extractJsonlLine('Syncing files to device...'), isNull);
      expect(extractJsonlLine(''), isNull);
      expect(extractJsonlLine('flutter: hello'), isNull);
    });

    test('rejects JSON that is not one of ours', () {
      // The reason this checks the shape instead of just "does it parse":
      // an app that logs an API response would otherwise poison the file
      // with objects `ailog_digest` counts as dropped events.
      expect(extractJsonlLine('{"id":7,"name":"widget"}'), isNull);
      expect(extractJsonlLine('[1,2,3]'), isNull);
      expect(extractJsonlLine('{"ts":123,"lvl":"info"}'), isNull);
      expect(extractJsonlLine('{"broken":'), isNull);
    });
  });

  group('webSocketUriFor', () {
    test('appends /ws to the observatory URI', () {
      expect(
        webSocketUriFor(Uri.parse('http://127.0.0.1:8181/9aoBbZBtew8=/'))
            .toString(),
        // The `=` padding in the token stays literal — the VM Service
        // rejects it percent-encoded.
        'ws://127.0.0.1:8181/9aoBbZBtew8=/ws',
      );
    });

    test('is idempotent, so a ws:// URI may be pasted directly', () {
      final once = webSocketUriFor(Uri.parse('http://127.0.0.1:8181/tok/'));
      expect(webSocketUriFor(once), once);
    });

    test('https maps to wss', () {
      expect(webSocketUriFor(Uri.parse('https://example.test/tok/')).scheme,
          'wss');
    });
  });

  group('debugSyncPayload', () {
    MemorySink filled(int count, {int capacity = 1000}) {
      final sink = MemorySink(capacity: capacity);
      final logger = Logger.forTesting(sink: sink);
      for (var i = 0; i < count; i++) {
        logger.info('event $i');
      }
      return sink;
    }

    test('a zero cursor returns everything', () {
      final payload = debugSyncPayload(filled(3), '0');

      expect(payload['events'], hasLength(3));
      expect(payload['highestSeq'], 3);
      expect(payload['missed'], 0);
    });

    test('a cursor returns only what came after it', () {
      final payload = debugSyncPayload(filled(5), '3');
      final events = (payload['events'] as List)
          .map((e) => jsonDecode(e as String) as Map<String, Object?>)
          .toList();

      expect(events.map((e) => e['seq']), [4, 5]);
      expect(payload['highestSeq'], 5);
    });

    test('an up-to-date cursor returns nothing and holds its place', () {
      final payload = debugSyncPayload(filled(5), '5');

      expect(payload['events'], isEmpty);
      expect(payload['highestSeq'], 5,
          reason: 'the cursor must not rewind when there is nothing new');
    });

    test('an unparseable cursor is treated as "send everything"', () {
      // Safer than treating it as "send nothing": a caller that garbles the
      // parameter gets duplicates, which the reader can see, rather than
      // silence, which they cannot.
      expect(debugSyncPayload(filled(2), null)['events'], hasLength(2));
      expect(debugSyncPayload(filled(2), 'x')['events'], hasLength(2));
    });

    test('events that rolled out of the window are counted, not hidden', () {
      // 10 logged, only the last 4 retained. A caller sitting at seq 2 has
      // permanently missed 3, 4, 5, 6.
      final payload = debugSyncPayload(filled(10, capacity: 4), '2');

      expect(payload['missed'], 4);
      expect(payload['events'], hasLength(4));
    });

    test('a first poll reports no loss, having asked for nothing yet', () {
      // sinceSeq 0 means "I have nothing", so there is no gap between what
      // the caller had and what survives — only a shorter history.
      expect(debugSyncPayload(filled(10, capacity: 4), '0')['missed'], 0);
    });

    test('an empty buffer is a valid, empty answer', () {
      final payload = debugSyncPayload(MemorySink(), '7');

      expect(payload['events'], isEmpty);
      expect(payload['session'], isNull);
      expect(payload['highestSeq'], 7);
    });

    test('the session id is carried so a restart is visible', () {
      final payload = debugSyncPayload(filled(2), '0');
      expect(payload['session'], isNotEmpty);
      expect(payload['schema'], aiLogSchemaVersion);
    });
  });

  group('installDebugSync', () {
    test('registers in a debug build and reports having done so', () {
      // `dart test` is JIT, so this is the branch a test can assert.
      final sync =
          installDebugSync(MemorySink(), extension: 'ext.ailog.syncTest1');

      expect(sync.registered, isTrue);
      expect(sync.extension, 'ext.ailog.syncTest1');
    });

    test('a duplicate registration is survived, not thrown', () {
      installDebugSync(MemorySink(), extension: 'ext.ailog.syncTest2');
      // dart:developer throws on a repeated name; a logger helper must not
      // take down the host program over it.
      expect(
        installDebugSync(MemorySink(), extension: 'ext.ailog.syncTest2')
            .registered,
        isFalse,
      );
    });

    test('the default extension name is what the CLI asks for', () {
      expect(defaultDebugSyncExtension, startsWith('ext.'));
    });
  });
}
