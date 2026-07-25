/// Producing something worth sending to an AI, as a string.
///
/// Simulates a connection-pool leak: every request takes a lease, but the
/// cache-hit path returns without giving it back. The pool drains and later
/// requests time out.
///
/// The interesting part is that no single request looks wrong. The leak is
/// only visible by counting across all of them — which is exactly what the
/// digest's "Event mix" section does, and exactly what a naive summary (or a
/// filter that keeps only the failing requests) would have thrown away.
///
/// Run with: `dart run example/ai_report_example.dart`
// Printing is the point of an example.
// ignore_for_file: avoid_print
library;

import 'package:ailog/ailog.dart';

Future<void> main() async {
  // Keep events in memory so the log can be handed back as a String. In a
  // real app this sits alongside the file sink:
  //   Logger.create(sink: MultiSink([fileSink, buffer]))
  final buffer = MemorySink(capacity: 5000);
  final logger = Logger.create(
    sink: buffer,
    minimumLevel: LogLevel.debug,
    causalChainLength: 6,
  );

  final http = logger.child('http');
  final pool = logger.child('pool');
  final cache = logger.child('cache');

  const poolSize = 20;
  var leased = 0;

  for (var i = 1; i <= 40; i++) {
    await runWithScope(LogScope(traceId: 'req-$i'), () async {
      http.info('GET /product/$i', context: {'endpoint': '/product/$i'});

      leased++;
      pool.debug('lease acquired',
          context: {'leased': leased, 'max': poolSize});

      if (leased >= poolSize) {
        http.error(
          StateError('PoolTimeout: no connection available after 5000ms'),
          StackTrace.current,
          message: 'request failed',
        );
        return;
      }

      if (i % 2 == 0 || i % 3 == 0) {
        cache.info('cache hit', context: {'key': 'product-$i'});
        // The bug: this path returns without releasing the lease.
        return;
      }

      leased--;
      pool.debug('lease released', context: {'leased': leased});
      http.info('200 OK', context: {'status': 200});
    });
  }

  await logger.flush();

  // 1. The digest alone — smallest, and enough to triage.
  final digest = buffer.toMarkdown();
  print(digest);

  // 2. Digest plus the events that survived filtering. This is the form to
  //    hand to an AI that is expected to actually diagnose something: the
  //    aggregates say *what* is inconsistent, the raw events show how.
  final report = buffer.export(LogFilter.forAi).toReport();

  // 3. Raw JSONL, identical in form to what JsonlFileSink writes.
  final jsonl = buffer.toJsonl();

  print('--- sizes ---');
  print('all events as JSONL : ${jsonl.length} bytes '
      '(${buffer.events.length} events)');
  print('digest only         : ${digest.length} bytes');
  print('digest + events     : ${report.length} bytes');

  // Whatever was filtered out is stated, so the result is never mistaken for
  // a complete log.
  final selection = buffer.export(LogFilter.forAi);
  print('dropped             : ${selection.droppedCount} '
      '(${selection.droppedBy})');
}
