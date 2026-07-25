// Minimal end-to-end example: write a JSONL log containing a redacted secret
// and a grouped error, then read it back through the digest CLI.
//
// Run: dart run example/main.dart
import 'package:ailog/ailog.dart';

Future<void> main() async {
  final fileSink = JsonlFileSink(path: '.ailog/app.jsonl');
  final logger = Logger.create(sink: MultiSink([fileSink, ConsoleSink()]));

  final scope = logger.startTrace(context: {'requestId': 'req-1'});
  await runWithScope(scope, () async {
    // The email address is masked before it reaches the file.
    logger.info(
      'handling checkout',
      context: {'userEmail': 'alice@example.com'},
    );

    try {
      await logger.span('charge_card', (span) async {
        throw Exception('card declined');
      });
    } catch (_) {
      // Already recorded by span(); swallowed here for the demo.
    }
  });

  await logger.flush();
  await fileSink.close();

  // ignore: avoid_print
  print(
    '\nWrote ${fileSink.path} — inspect it with:\n'
    '  dart run ailog:ailog_digest ${fileSink.path}',
  );
}
