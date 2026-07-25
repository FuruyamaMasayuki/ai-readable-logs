// より実践的な使い方の例:
//
// - サブシステムごとの子ロガー (db / http)
// - 開発時はコンソールに warn 以上のみ、ファイルには全レベルを記録
// - カスタムの機密情報マスキングルールとサニタイズ上限
// - 複数サブシステムをまたいだトレース内での因果チェーン
// - DigestBuilder をCLIを介さずライブラリとして直接使う
//
// Run: dart run example/advanced_example.dart
import 'dart:io';

import 'package:ailog/ailog.dart';

Future<void> main() async {
  // 標準ルールに加えて、社内チケットID (TICKET-1234 のような形式) もマスクする。
  final redactor = Redactor(
    rules: [
      ...builtInRedactionRules.where((r) => r.enabledByDefault),
      RedactionRule(name: 'ticket', pattern: RegExp(r'\bTICKET-\d{3,}\b')),
    ],
  );

  final logFile =
      '${Directory.systemTemp.path}/ailog_advanced_example/app.jsonl';
  final fileSink = JsonlFileSink(path: logFile, flushInterval: Duration.zero);

  final logger = Logger.create(
    sink: MultiSink([
      fileSink, // ファイルには全レベルを記録
      LevelFilterSink(ConsoleSink(), LogLevel.warn), // コンソールは開発時の目視用
    ]),
    redactor: redactor,
    limits: SanitizerLimits.compact, // AIに読ませる前提で値を短く保つ
  );

  final dbLogger = logger.child('db');
  final httpLogger = logger.child('http');

  final scope = logger.startTrace(context: {'requestId': 'req-42'});
  await runWithScope(scope, () async {
    httpLogger.info('GET /orders/42', context: {'ticket': 'TICKET-9821'});

    await dbLogger.span('query orders', (span) async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    });

    try {
      await dbLogger.span('query payment', (span) async {
        throw Exception('connection reset');
      });
    } catch (_) {
      // すでに span() 内で記録済みなのでここでは握りつぶすだけ。
    }

    httpLogger.errorMessage(
      '500 for GET /orders/42',
      context: {'userEmail': 'alice@example.com'},
    );
  });

  await logger.flush();
  await fileSink.close();

  // ailog_digest はCLIとしてだけでなく、DigestBuilder を直接使って
  // アプリ内(例: 管理画面やSlack通知)に組み込むこともできる。
  final builder = DigestBuilder();
  for (final line in File(logFile).readAsLinesSync()) {
    builder.addLine(line);
  }
  // ignore: avoid_print
  print(builder.build().toMarkdown(maxGroups: 5));
}
