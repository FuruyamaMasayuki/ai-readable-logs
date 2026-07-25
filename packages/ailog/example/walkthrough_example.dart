// A guided tour of everything, in the order you would actually meet it.
//
//   dart run example/walkthrough_example.dart
//
// Simulates a small order service handling six requests, one of which
// fails, then shows what an AI would be given to diagnose it.
//
// ignore_for_file: avoid_print
library;

import 'dart:io';

import 'package:ailog/ailog.dart';

Future<void> main() async {
  final logDir = Directory('${Directory.systemTemp.path}/ailog_walkthrough')
    ..createSync(recursive: true);
  final logPath = '${logDir.path}/app.jsonl';
  File(logPath).existsSync() ? File(logPath).deleteSync() : null;

  // ── 1. Create the logger ────────────────────────────────────────────────
  //
  // Two sinks: the file is the artifact you hand to an AI, the console is
  // for you. LevelFilterSink keeps the console quiet without making the
  // file lossy — they do not have to agree.
  //
  // A MemorySink alongside them means the same events can be handed back as
  // a String later, without reading the file.
  final recent = MemorySink(capacity: 500);
  final logger = Logger.create(
    sink: MultiSink([
      JsonlFileSink(path: logPath),
      LevelFilterSink(ConsoleSink.usingPrint(), LogLevel.warn),
      recent,
    ]),
    // Everything in dev, info and up in release. See build_modes_example.
    minimumLevel: byBuildMode(debug: LogLevel.trace, release: LogLevel.info),
    // Merged into every event, with no scope needed — so it also covers
    // timers, isolates, and anything logged before a trace starts.
    baseContext: {'service': 'orders', 'version': '2.1.0'},
    // Note what is *not* here: includePlatformContext. JsonlFileSink writes
    // the OS and Dart version into the file's header once; merging them
    // into every event costs 133 bytes a line for an answer that never
    // changes.
  );

  // ── 2. Subsystem loggers ────────────────────────────────────────────────
  //
  // Children share the session, sequence counter and causal buffer, so
  // events from different subsystems in one trace still weave together.
  final http = logger.child('http');
  final db = logger.child('db');
  final cache = logger.child('cache');

  // ── 3. Handle some requests ─────────────────────────────────────────────
  for (var i = 1; i <= 6; i++) {
    // One trace per request. Everything logged inside inherits the ids —
    // including across `await`, without threading a parameter through.
    await runWithScope(
      logger.startTrace(context: {'requestId': 'req-$i'}),
      () => handleRequest(i, http: http, db: db, cache: cache),
    );
  }

  // Push buffered lines to disk before reading the file back, then close.
  //
  // close() matters here, not just flush(): JsonlFileSink schedules a
  // periodic Timer (flushInterval, default 2s) to auto-flush, and only
  // close() cancels it. A live Timer keeps the isolate alive — flush()
  // alone leaves this script hanging forever instead of exiting.
  await logger.flush();
  await logger.close();

  // ── 4. What you now have ────────────────────────────────────────────────
  final bytes = File(logPath).lengthSync();
  print('');
  print('── wrote ${recent.events.length} events, $bytes bytes → $logPath');
  print('');

  // (a) The digest: what broke, how often, what led up to it.
  print('── digest ${'─' * 60}');
  print(recent.toMarkdown());

  // (b) A filtered report: digest plus the events worth reading, as a
  //     String. This is the form to hand to an AI that should actually
  //     diagnose something rather than triage it.
  final selection = recent.export(LogFilter.forAi);
  print('── filtered for an AI ${'─' * 48}');
  print('kept ${selection.events.length} of ${selection.inputCount} events '
      '(dropped: ${selection.droppedBy})');
  print('report size: ${selection.toReport().length} bytes '
      'vs ${recent.toJsonl().length} bytes unfiltered');
  print('');

  // (c) The raw file is still there, and `ailog_digest` reads it:
  print('── or, from the command line ${'─' * 41}');
  print('dart run ailog:ailog_digest $logPath');
}

Future<void> handleRequest(
  int id, {
  required Logger http,
  required Logger db,
  required Logger cache,
}) async {
  http.info('GET /orders/$id', context: {'endpoint': '/orders/$id'});

  // checkpoint() records *where* it ran, with no message to invent. Useful
  // for proving a branch was taken; it stays correct when the code moves.
  http.checkpoint();

  // A span measures a step. Duration is recorded on success, and on failure
  // the error, its duration and the causal chain are all recorded — while
  // the exception still propagates, so control flow is unchanged.
  try {
    await http.span('load_order', (span) async {
      cache.debug('cache lookup', context: {'key': 'order-$id'});

      if (id % 3 == 0) {
        cache.debug('cache miss', context: {'key': 'order-$id'});
        await db.span('query', (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 2));
          // Request 3 is the one that fails.
          if (id == 3) {
            throw StateError('connection pool exhausted');
          }
        });
      } else {
        cache.debug('cache hit', context: {'key': 'order-$id'});
      }

      // Secrets are masked automatically — this email never reaches the
      // file in clear text, but the same address produces the same hash, so
      // "these lines are the same user" survives redaction.
      http.info('order loaded',
          context: {'customerEmail': 'user$id@example.com'});
    });

    http.info('200 OK', context: {'status': 200});
  } catch (error, stackTrace) {
    // The error line will carry: a fingerprint (so repeats group), the
    // normalized stack, this context, and the causal chain — the cache
    // lookup, the miss, the query — all embedded in the one line.
    http.error(error, stackTrace, message: 'request failed');
  }
}
