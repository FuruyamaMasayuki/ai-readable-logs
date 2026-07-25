// Compile target that proves the package builds for web.
//
// `dart analyze` and `dart test` both run on the VM, where a 64-bit int is
// a normal int. Under dart2js it is a *compile error* — and one such literal
// sat in ids.dart making the entire package unbuildable for web, silently,
// because nothing in CI ever compiled it that way.
//
// CI runs `dart compile js tool/web_entry.dart`. It exists to fail loudly.
//
// Deliberately touches everything reachable on web: JsonlFileSink is excluded
// because it is VM-only by design (see the conditional export in
// lib/src/sinks/jsonl_file_sink.dart).
//
// ignore_for_file: avoid_print
library;

import 'package:ailog/ailog.dart';

void main() {
  final buffer = MemorySink();
  final logger = Logger.create(
    sink: MultiSink([
      buffer,
      JsonlPrintSink(),
      RateLimitSink(buffer),
      LevelFilterSink(ConsoleSink.usingPrint(), LogLevel.warn),
    ]),
    minimumLevel: byBuildMode(debug: LogLevel.trace, release: LogLevel.info),
  );

  runWithScope(logger.startTrace(context: {'requestId': 'r1'}), () {
    logger.info('hello', context: {'email': 'a@example.com'});
    logger.checkpoint();
    try {
      throw StateError('boom');
    } catch (error, stackTrace) {
      logger.error(error, stackTrace);
    }
  });

  capturePrints(logger, () => print('captured'));

  // The read-side APIs, which are the whole point of running this on web.
  print(buffer.toMarkdown().length);
  print(buffer.toJsonl().length);
  print(buffer.export(LogFilter.forAi).toReport().length);
  print(digestFromJsonl(buffer.toJsonl()).totalEvents);
  print(shortHash('fingerprint-me'));
  print(fnv1a64Hex('fingerprint-me'));
}
