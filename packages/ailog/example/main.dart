// Start here. The smallest useful ailog setup, end to end.
//
//   dart run example/main.dart
//   dart run ailog:ailog_digest .ailog/app.jsonl
//
// The other files in this directory each go one step further; see the table
// in the package README.
//
// ignore_for_file: avoid_print
library;

import 'package:ailog/ailog.dart';

Future<void> main() async {
  // One logger per process. JsonlFileSink writes the file an AI reads;
  // ConsoleSink is the human-readable copy you watch while developing.
  //
  // On Flutter, a relative path like this is not writable on a device — use
  // path_provider's getApplicationSupportDirectory(). See ailog_flutter.
  final logger = Logger.create(
    sink: MultiSink([
      JsonlFileSink(path: '.ailog/app.jsonl'),
      ConsoleSink(),
    ]),
  );

  // A trace ties related lines together. Everything logged inside — even
  // after an `await` — carries its id automatically, with no parameter
  // threaded through your functions.
  await runWithScope(logger.startTrace(context: {'requestId': 'req-1'}),
      () async {
    // The email is masked before it reaches the file, and the same address
    // always masks to the same token, so you can still tell "same user".
    logger
        .info('handling checkout', context: {'userEmail': 'alice@example.com'});

    try {
      // span() times the step. On failure it records the error, how long it
      // took, and the events that led up to it — then rethrows, so your
      // control flow is unchanged.
      await logger.span('charge_card', (span) async {
        throw Exception('card declined');
      });
    } catch (_) {
      // Already recorded by span(); swallowed here so the demo finishes.
    }
  });

  // close() flushes *and* stops the sink's background flush timer. Without
  // it a short script like this one never exits.
  await logger.close();

  print('\nWrote .ailog/app.jsonl — now summarize it:\n'
      '  dart run ailog:ailog_digest .ailog/app.jsonl');
}
