import 'dart:convert';
import 'dart:io';

import 'package:ailog/ailog.dart';
import 'package:test/test.dart';

LogEvent _event(String message, {int seq = 1}) => LogEvent(
      time: DateTime.utc(2026, 1, 1),
      level: LogLevel.info,
      message: message,
      logger: 'app',
      sessionId: 's',
      sequence: seq,
    );

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ailog_sink_test');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('JsonlFileSink', () {
    test('creates missing parent directories', () {
      final path = '${tempDir.path}/nested/dir/app.jsonl';
      final sink = JsonlFileSink(path: path, flushInterval: Duration.zero);
      sink.add(_event('hello'));
      expect(File(path).existsSync(), isTrue);
    });

    test('writes a schema header as the first line of a new file', () async {
      final path = '${tempDir.path}/app.jsonl';
      final sink = JsonlFileSink(path: path, flushInterval: Duration.zero);
      sink.add(_event('hello'));
      await sink.flush();
      await sink.close();

      final lines = File(path).readAsLinesSync();
      final header = jsonDecode(lines.first) as Map<String, Object?>;
      expect(header['_hdr'], isTrue);
      expect(header['schema'], aiLogSchemaVersion);
      expect(header['legend'], isA<Map>());
      expect(lines.length, 2, reason: 'header + one event');
    });

    test('writeSchemaHeader: false omits the header line', () async {
      final path = '${tempDir.path}/app.jsonl';
      final sink = JsonlFileSink(
        path: path,
        flushInterval: Duration.zero,
        writeSchemaHeader: false,
      );
      sink.add(_event('hello'));
      await sink.flush();
      await sink.close();

      final lines = File(path).readAsLinesSync();
      expect(lines.length, 1);
      final decoded = jsonDecode(lines.single) as Map<String, Object?>;
      expect(decoded['msg'], 'hello');
    });

    test('every line is independently parseable JSON', () async {
      final path = '${tempDir.path}/app.jsonl';
      final sink = JsonlFileSink(path: path, flushInterval: Duration.zero);
      for (var i = 0; i < 5; i++) {
        sink.add(_event('event $i', seq: i));
      }
      await sink.flush();
      await sink.close();

      final lines = File(path).readAsLinesSync();
      for (final line in lines) {
        expect(() => jsonDecode(line), returnsNormally);
      }
    });

    test('reopening an existing non-empty file does not rewrite the header',
        () async {
      final path = '${tempDir.path}/app.jsonl';
      final first = JsonlFileSink(path: path, flushInterval: Duration.zero);
      first.add(_event('first session'));
      await first.close();

      final second = JsonlFileSink(path: path, flushInterval: Duration.zero);
      second.add(_event('second session'));
      await second.close();

      final lines = File(path).readAsLinesSync();
      final headers =
          lines.where((l) => (jsonDecode(l) as Map)['_hdr'] == true);
      expect(headers, hasLength(1), reason: 'header should only appear once');
      expect(lines.length, 3, reason: 'header + 2 events across both sessions');
    });

    test('rotates the file once maxBytes is exceeded', () async {
      final path = '${tempDir.path}/app.jsonl';
      // A tiny maxBytes forces rotation on the very first sizeable event.
      final sink = JsonlFileSink(
        path: path,
        flushInterval: Duration.zero,
        maxBytes: 50,
        writeSchemaHeader: false,
      );

      sink.add(_event('short'));
      await sink.flush();
      // This write pushes _bytesWritten past maxBytes, so the *next* add()
      // rotates before writing.
      sink.add(_event('a much longer message to exceed the byte budget'));
      await sink.flush();
      sink.add(_event('after rotation'));
      await sink.flush();
      await sink.close();

      expect(File(path).existsSync(), isTrue);
      expect(File('$path.1').existsSync(), isTrue);

      final rotatedLines = File('$path.1').readAsLinesSync();
      expect(rotatedLines, isNotEmpty);
      final activeLines = File(path).readAsLinesSync();
      expect(activeLines.last, contains('after rotation'));
    });

    test('keeps at most maxFiles rotated files', () async {
      final path = '${tempDir.path}/app.jsonl';
      final sink = JsonlFileSink(
        path: path,
        flushInterval: Duration.zero,
        maxBytes: 10,
        maxFiles: 2,
        writeSchemaHeader: false,
      );

      // Each add() exceeds the 10-byte budget, forcing rotation every time.
      for (var i = 0; i < 6; i++) {
        sink.add(_event('event number $i is long enough to rotate'));
        await sink.flush();
      }
      await sink.close();

      expect(File(path).existsSync(), isTrue);
      expect(File('$path.1').existsSync(), isTrue);
      expect(File('$path.2').existsSync(), isTrue);
      expect(File('$path.3').existsSync(), isFalse);
    });

    test('flush() does not throw', () async {
      final path = '${tempDir.path}/app.jsonl';
      final sink = JsonlFileSink(path: path, flushInterval: Duration.zero);
      sink.add(_event('hello'));
      await expectLater(sink.flush(), completes);
      await sink.close();
    });

    test('close() is idempotent', () async {
      final path = '${tempDir.path}/app.jsonl';
      final sink = JsonlFileSink(path: path, flushInterval: Duration.zero);
      sink.add(_event('hello'));
      await sink.close();
      await expectLater(sink.close(), completes);
    });

    test('add() after close() is a silent no-op', () async {
      final path = '${tempDir.path}/app.jsonl';
      final sink = JsonlFileSink(path: path, flushInterval: Duration.zero);
      sink.add(_event('before close'));
      await sink.close();

      sink.add(_event('after close'));

      final lines = File(path).readAsLinesSync();
      expect(lines.any((l) => l.contains('after close')), isFalse);
    });

    test('path getter reflects the constructor argument', () {
      final path = '${tempDir.path}/app.jsonl';
      final sink = JsonlFileSink(path: path, flushInterval: Duration.zero);
      expect(sink.path, path);
    });
  });
}
