// Measures what logging actually costs, so the README's numbers can be
// checked rather than believed.
//
//   dart run benchmark/logging_benchmark.dart          # JIT
//   dart compile exe benchmark/logging_benchmark.dart -o /tmp/bench && /tmp/bench
//
// Prefer the compiled run for anything you plan to quote: JIT warm-up and
// the absence of AOT optimizations both distort the numbers, usually by
// more than the differences being measured.
//
// ignore_for_file: avoid_print
library;

import 'package:ailog/ailog.dart';

/// A sink that does nothing, so the measurement is of the logger rather than
/// of the filesystem. Serialization is still exercised where it matters —
/// see the `toJson` case.
class _NullSink implements LogSink {
  int count = 0;

  @override
  void add(LogEvent event) => count++;

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}

double _measure(String label, int iterations, void Function() body) {
  // Warm up so JIT compilation isn't attributed to the first case measured.
  for (var i = 0; i < iterations ~/ 10 + 1; i++) {
    body();
  }
  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    body();
  }
  watch.stop();
  final perCall = watch.elapsedMicroseconds / iterations;
  final rendered = perCall >= 1
      ? '${perCall.toStringAsFixed(2)} µs'
      : '${(perCall * 1000).toStringAsFixed(0)} ns';
  print('${label.padRight(46)} $rendered');
  return perCall;
}

void main() {
  print('build mode: ${currentBuildMode.name}');
  print('');

  final sink = _NullSink();
  final logger = Logger.create(sink: sink, causalChainLength: 10);

  const context = {
    'requestId': 'req-1',
    'endpoint': '/product/42',
    'status': 200,
    'durationMs': 31,
    'cacheHit': true,
    'retries': 0,
  };

  _measure('info, no context', 200000, () {
    logger.info('checkout started');
  });

  _measure('info with 6 context fields', 200000, () {
    logger.info('checkout started', context: context);
  });

  final stackTrace = StackTrace.current;
  final error = StateError('card declined');
  _measure('error with a stack trace', 50000, () {
    logger.error(error, stackTrace);
  });

  // The case that decides whether leaving log calls in hot paths is safe.
  final quiet = Logger.create(
    sink: _NullSink(),
    minimumLevel: LogLevel.warn,
    breadcrumbLevel: LogLevel.warn,
    causalChainLength: 0,
  );
  _measure('debug filtered out by minimumLevel', 500000, () {
    quiet.debug('cache hit', context: context);
  });

  // Breadcrumbs on: the level is still filtered from the sink, but the event
  // is retained for a future causal chain. This is the cost of the default
  // configuration, and the reason breadcrumbs are stored unsanitized.
  final buffering = Logger.create(
    sink: _NullSink(),
    minimumLevel: LogLevel.info,
    breadcrumbLevel: LogLevel.trace,
    causalChainLength: 10,
  );
  _measure('debug filtered, but kept as a breadcrumb', 200000, () {
    buffering.debug('cache hit', context: context);
  });

  final disabled = Logger.disabled();
  _measure('any call on a disabled logger', 500000, () {
    disabled.info('never emitted', context: context);
  });

  // Serialization, measured separately: JsonlFileSink pays this per line.
  final event = LogEvent(
    time: DateTime.now(),
    level: LogLevel.error,
    message: 'card declined',
    logger: 'app',
    sessionId: 'session',
    sequence: 1,
    traceId: 'trace',
    context: context,
    error: ErrorInfo(
      type: 'StateError',
      message: 'card declined',
      fingerprint: 'abcd1234',
      frames: const ['checkout.dart:42 CartService.charge'],
    ),
  );
  _measure('LogEvent.toJson', 500000, () {
    event.toJson();
  });

  print('');
  print('(${sink.count} events reached the sink)');
}
