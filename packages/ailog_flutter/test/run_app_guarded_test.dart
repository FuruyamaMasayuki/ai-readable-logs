import 'dart:async';

import 'package:ailog_flutter/ailog_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runs body inside a shared trace scope', () {
    final sink = MemorySink();
    final logger = Logger.forTesting(sink: sink);

    runAppGuarded(logger, () {
      logger.info('inside body');
    });

    expect(sink.events.single.traceId, isNotNull);
  });

  test('logs uncaught zone errors as fatal instead of crashing the process',
      () async {
    final sink = MemorySink();
    final logger = Logger.forTesting(sink: sink);

    runAppGuarded(logger, () {
      scheduleMicrotask(() {
        throw StateError('escaped a callback');
      });
    });

    // Drain the microtask/timer queue so the throw reaches the zone's
    // uncaught error handler before we assert on the sink.
    await pumpEventQueue();

    expect(sink.events, hasLength(1));
    expect(sink.events.single.level, LogLevel.fatal);
    expect(sink.events.single.tags, contains('uncaught'));
  });
}
