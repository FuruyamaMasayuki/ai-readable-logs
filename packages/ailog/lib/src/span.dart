/// A timed unit of work, correlated to a trace.
///
/// A span is the thing an AI reading the log wants to know finished, how long
/// it took, and whether it succeeded — "checkout.charge took 812ms and threw
/// `PaymentDeclined`" is a complete diagnosis in one line.
library;

import 'dart:async';

import 'context.dart';
import 'logger.dart';
import 'log_level.dart';

/// Handle returned by [Logger.startSpan].
///
/// Must be completed with [succeed] or [fail] (or use [Logger.span] /
/// [Logger.spanAsync], which do this automatically).
class Span {
  Span.fromLogger(this._logger, this._scope, this.name)
      : _startedAt = DateTime.now();

  final Logger _logger;
  final LogScope _scope;
  final String name;
  final DateTime _startedAt;
  bool _finished = false;

  /// The scope to run the span's body in, so nested logs inherit trace/span.
  LogScope get scope => _scope;

  String? get traceId => _scope.traceId;
  String? get spanId => _scope.spanId;

  int get elapsedMs => DateTime.now().difference(_startedAt).inMilliseconds;

  /// Marks the span as successfully completed.
  void succeed({String? message, Map<String, Object?>? context}) {
    if (_finished) return;
    _finished = true;
    runWithScope(_scope, () {
      _logger.log(
        LogLevel.info,
        message ?? '$name completed',
        context: context,
        durationMs: elapsedMs,
      );
    });
  }

  /// Marks the span as failed. This still produces a single event; use
  /// [Logger.error] separately if the failure also needs to be logged in a
  /// different trace context.
  void fail(Object error,
      [StackTrace? stackTrace, Map<String, Object?>? context]) {
    if (_finished) return;
    _finished = true;
    runWithScope(_scope, () {
      _logger.errorEvent(
        error,
        stackTrace,
        message: '$name failed',
        context: context,
        durationMs: elapsedMs,
      );
    });
  }
}

/// Runs [body] inside a new span, auto-closing it on return or throw.
///
/// This is what most call sites should use instead of [Logger.startSpan]
/// directly — there is no code path that leaves the span open.
Future<T> runSpanAsync<T>(
  Logger logger,
  String name,
  Future<T> Function(Span span) body, {
  Map<String, Object?>? context,
}) async {
  final span = logger.startSpan(name, context: context);
  try {
    final result = await runWithScope(span.scope, () => body(span));
    span.succeed();
    return result;
  } catch (error, stackTrace) {
    span.fail(error, stackTrace);
    rethrow;
  }
}

/// Synchronous counterpart of [runSpanAsync].
T runSpan<T>(
  Logger logger,
  String name,
  T Function(Span span) body, {
  Map<String, Object?>? context,
}) {
  final span = logger.startSpan(name, context: context);
  try {
    final result = runWithScope(span.scope, () => body(span));
    span.succeed();
    return result;
  } catch (error, stackTrace) {
    span.fail(error, stackTrace);
    rethrow;
  }
}
