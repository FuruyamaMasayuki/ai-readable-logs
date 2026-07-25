import 'dart:convert';
import 'dart:io';

import 'package:ailog/ailog.dart';
import 'package:ailog_vault/ailog_vault.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('av_digest_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<void> writeLog(String name, List<LogEvent> events) async {
    final sink = File('${tempDir.path}/$name');
    final buffer = StringBuffer();
    for (final e in events) {
      buffer.writeln(jsonEncode(e.toJson()));
    }
    await sink.writeAsString(buffer.toString());
  }

  LogEvent event(String message, int seq,
          {LogLevel level = LogLevel.info}) =>
      LogEvent(
        time: DateTime.utc(2026, 1, 1, 0, 0, seq),
        level: level,
        message: message,
        logger: 'app',
        sessionId: 's',
        sequence: seq,
      );

  test('reads the jsonl files, writes digest.md beside them', () async {
    await writeLog('app.jsonl', [event('hello', 1), event('world', 2)]);

    final digest = await writeDigestForDirectory(tempDir);

    expect(digest.totalEvents, 2);
    final md = File('${tempDir.path}/digest.md');
    expect(md.existsSync(), isTrue);
    expect(md.readAsStringSync(), contains('# Log digest'));
  });

  test('rotations are read oldest first', () async {
    await writeLog('app.jsonl.2', [event('oldest', 1)]);
    await writeLog('app.jsonl.1', [event('middle', 2)]);
    await writeLog('app.jsonl', [event('newest', 3)]);

    final digest = await writeDigestForDirectory(tempDir);

    expect(digest.totalEvents, 3);
    expect(digest.timeRange.$1, DateTime.utc(2026, 1, 1, 0, 0, 1));
    expect(digest.timeRange.$2, DateTime.utc(2026, 1, 1, 0, 0, 3));
  });

  test('non-jsonl files are ignored', () async {
    await writeLog('app.jsonl', [event('yes', 1)]);
    File('${tempDir.path}/notes.txt').writeAsStringSync('{"msg":"no"}\n');

    final digest = await writeDigestForDirectory(tempDir);

    expect(digest.totalEvents, 1);
  });

  test('a missing directory still produces a digest file', () async {
    final missing = Directory('${tempDir.path}/never_created');

    final digest = await writeDigestForDirectory(missing);

    expect(digest.totalEvents, 0);
    expect(File('${missing.path}/digest.md').existsSync(), isTrue);
  });

  test('the digest counts errors from the files', () async {
    await writeLog('app.jsonl', [
      event('fine', 1),
      LogEvent(
        time: DateTime.utc(2026, 1, 1, 0, 0, 2),
        level: LogLevel.error,
        message: 'boom',
        logger: 'app',
        sessionId: 's',
        sequence: 2,
        error: ErrorInfo(type: 'E', message: 'boom', fingerprint: 'f1'),
      ),
    ]);

    final digest = await writeDigestForDirectory(tempDir);

    expect(digest.errorGroups, hasLength(1));
    expect(File('${tempDir.path}/digest.md').readAsStringSync(),
        contains('`E`'));
  });
}
