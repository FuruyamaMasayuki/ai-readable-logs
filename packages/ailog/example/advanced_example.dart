// A more realistic setup:
//
// - per-subsystem child loggers (db / http)
// - warnings and above on the console, everything in the file
// - a custom redaction rule and tighter sanitizer limits
// - a causal chain spanning several subsystems within one trace
// - checkpoints: recording that code ran, without writing a message
// - using DigestBuilder as a library rather than through the CLI
//
// Run: dart run example/advanced_example.dart
import 'dart:io';

import 'package:ailog/ailog.dart';

Future<void> main() async {
  // Alongside the built-in rules, mask internal ticket IDs like TICKET-1234.
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
      fileSink, // everything
      LevelFilterSink(ConsoleSink(), LogLevel.warn), // just what you watch
    ]),
    redactor: redactor,
    limits: SanitizerLimits.compact, // keep values short for AI consumption
  );

  final dbLogger = logger.child('db');
  final httpLogger = logger.child('http');

  final scope = logger.startTrace(context: {'requestId': 'req-42'});
  await runWithScope(scope, () async {
    httpLogger.info('GET /orders/42', context: {'ticket': 'TICKET-9821'});

    // No message: the line records where it was called instead. Useful for
    // proving a branch executed without inventing a string for it.
    dbLogger.checkpoint();

    await dbLogger.span('query orders', (span) async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    });

    try {
      await dbLogger.span('query payment', (span) async {
        throw Exception('connection reset');
      });
    } catch (_) {
      // Already recorded inside span(); swallowed here.
    }

    httpLogger.errorMessage(
      '500 for GET /orders/42',
      context: {'userEmail': 'alice@example.com'},
    );
  });

  await logger.flush();
  await fileSink.close();

  // The digest is available as a library too, not just via the CLI — handy
  // for an admin screen or a Slack notification.
  final builder = DigestBuilder();
  for (final line in File(logFile).readAsLinesSync()) {
    builder.addLine(line);
  }
  // ignore: avoid_print
  print(builder.build().toMarkdown(maxGroups: 5));
}
