/// The public entry point: create one [Logger], derive children from it.
library;

import 'dart:async';

import 'call_site.dart';
import 'causal_buffer.dart';
import 'context.dart';
import 'ids.dart';
import 'log_event.dart';
import 'log_level.dart';
import 'redaction.dart';
import 'sanitizer.dart';
import 'sinks/log_sink.dart';
import 'span.dart';

export 'span.dart' show Span, runSpan, runSpanAsync;

/// Shared state for a family of [Logger] instances created via [Logger.child].
///
/// Kept separate from [Logger] so that "one session" has one sink, one
/// sequence counter and one causal buffer no matter how many named child
/// loggers are derived from it.
class _LoggerCore {
  _LoggerCore({
    required this.sink,
    required this.sanitizer,
    required this.minimumLevel,
    required this.sessionId,
    required this.causalChainLength,
    IdGenerator? idGenerator,
  })  : idGenerator = idGenerator ?? IdGenerator(),
        sequence = SequenceCounter(),
        causalBuffer = CausalBuffer();

  final LogSink sink;
  final Sanitizer sanitizer;
  final LogLevel minimumLevel;
  final String sessionId;
  final int causalChainLength;
  final IdGenerator idGenerator;
  final SequenceCounter sequence;
  final CausalBuffer causalBuffer;
}

/// A logger optimized for producing AI-analyzable, self-contained JSONL
/// output.
///
/// Create one root logger per process (see [Logger.create]), then derive
/// named children with [child] for subsystems ("db", "http", "auth"). All
/// children of the same root share a session id, sequence counter and causal
/// buffer, so events from different subsystems in the same trace still weave
/// together correctly.
class Logger {
  Logger._(this._core, this.name);

  final _LoggerCore _core;

  /// Subsystem name, written as `lg` in every event.
  final String name;

  /// Creates a root logger.
  ///
  /// [sink] is where events go; combine sinks with [MultiSink] for "file +
  /// console". [redactor] controls automatic masking — pass
  /// `Redactor.disabled()` only for local, throwaway debugging.
  /// [causalChainLength] bounds how many preceding events are attached to
  /// each error (`0` disables the feature).
  factory Logger.create({
    required LogSink sink,
    String name = 'app',
    LogLevel minimumLevel = LogLevel.trace,
    Redactor? redactor,
    SanitizerLimits limits = const SanitizerLimits(),
    int causalChainLength = 10,
    String? sessionId,
  }) {
    final core = _LoggerCore(
      sink: sink,
      sanitizer: Sanitizer(redactor: redactor, limits: limits),
      minimumLevel: minimumLevel,
      sessionId: sessionId ?? IdGenerator().traceId(),
      causalChainLength: causalChainLength,
    );
    return Logger._(core, name);
  }

  /// A logger backed by [MemorySink], useful for tests.
  factory Logger.forTesting({
    MemorySink? sink,
    LogLevel minimumLevel = LogLevel.trace,
    Redactor? redactor,
  }) =>
      Logger.create(
        sink: sink ?? MemorySink(),
        minimumLevel: minimumLevel,
        redactor: redactor ?? Redactor.disabled(),
        sessionId: 'test-session',
      );

  /// Derives a child logger for a named subsystem, sharing this logger's sink,
  /// session and causal buffer.
  Logger child(String name) => Logger._(_core, name);

  String get sessionId => _core.sessionId;

  // --- Trace / span lifecycle -------------------------------------------

  /// Starts a new trace (e.g. one incoming request), returning a [LogScope]
  /// to run the request's handling inside via [runWithScope].
  LogScope startTrace(
      {Map<String, Object?>? context, List<String> tags = const []}) {
    return currentScope.child(
      traceId: _core.idGenerator.traceId(),
      spanId: _core.idGenerator.spanId(),
      fields: context,
      tags: tags,
    );
  }

  /// Runs [body] inside a fresh trace. Prefer this over [startTrace] +
  /// [runWithScope] when the trace should not outlive [body].
  Future<T> traceAsync<T>(
    String name,
    Future<T> Function() body, {
    Map<String, Object?>? context,
  }) {
    final scope = startTrace(context: context);
    return runWithScope(scope, () => runSpanAsync(this, name, (_) => body()));
  }

  /// Starts a child span under the current scope's trace.
  ///
  /// If there is no active trace yet, one is created implicitly so a span is
  /// never orphaned.
  Span startSpan(String name, {Map<String, Object?>? context}) {
    var scope = currentScope;
    if (scope.traceId == null) {
      scope = scope.child(traceId: _core.idGenerator.traceId());
    }
    final spanScope =
        scope.child(spanId: _core.idGenerator.spanId(), fields: context);
    return Span.fromLogger(this, spanScope, name);
  }

  /// Runs [body] as a span, auto-closing on return or throw.
  Future<T> span<T>(
    String name,
    Future<T> Function(Span span) body, {
    Map<String, Object?>? context,
  }) =>
      runSpanAsync(this, name, body, context: context);

  /// Synchronous counterpart of [span].
  T spanSync<T>(
    String name,
    T Function(Span span) body, {
    Map<String, Object?>? context,
  }) =>
      runSpan(this, name, body, context: context);

  // --- Leveled logging -----------------------------------------------------

  //
  // Every method here also accepts a null [message]. Passing null — or
  // calling [checkpoint] — turns the call into a **checkpoint**: ailog
  // captures the call site and logs
  // `→ package:my_app/checkout.dart:42 CartService.charge` instead, plus a
  // `checkpoint` tag. That beats a hand-written `'here'` string for proving
  // a path ran, and it stays correct when the code moves.
  //

  void trace(
    String? message, {
    Map<String, Object?>? context,
    List<String>? tags,
  }) =>
      log(LogLevel.trace, message, context: context, tags: tags);

  void debug(
    String? message, {
    Map<String, Object?>? context,
    List<String>? tags,
  }) =>
      log(LogLevel.debug, message, context: context, tags: tags);

  void info(
    String? message, {
    Map<String, Object?>? context,
    List<String>? tags,
  }) =>
      log(LogLevel.info, message, context: context, tags: tags);

  void warn(
    String? message, {
    Map<String, Object?>? context,
    List<String>? tags,
  }) =>
      log(LogLevel.warn, message, context: context, tags: tags);

  /// Logs a message at [LogLevel.error]. For a caught exception, prefer
  /// [error] so the fingerprint and stack frames are captured.
  void errorMessage(
    String? message, {
    Map<String, Object?>? context,
    List<String>? tags,
  }) =>
      log(LogLevel.error, message, context: context, tags: tags);

  /// Records that this line of code ran, without writing a message.
  ///
  /// The emitted event's `msg` becomes the call site
  /// (`→ package:my_app/checkout.dart:42 CartService.charge`) and it is
  /// tagged `checkpoint`. Use it to make a code path's execution visible
  /// without inventing throwaway strings:
  ///
  /// ```dart
  /// Future<void> charge() async {
  ///   logger.checkpoint();          // → checkout.dart:12 CartService.charge
  ///   await gateway.send();
  ///   logger.checkpoint();          // → checkout.dart:14 CartService.charge
  /// }
  /// ```
  ///
  /// Defaults to [LogLevel.trace], so a production `minimumLevel` of `debug`
  /// or higher filters checkpoints out and they cost nothing there — the
  /// call site is only captured after the level check passes.
  ///
  /// `logger.info(null)` is equivalent at a different level. (Dart does not
  /// allow optional positional and named parameters in one signature, so
  /// `logger.info()` with no arguments at all cannot coexist with the
  /// `context:`/`tags:` named parameters — hence the explicit `null`.)
  void checkpoint({
    LogLevel level = LogLevel.trace,
    Map<String, Object?>? context,
    List<String>? tags,
  }) =>
      log(level, null, context: context, tags: tags);

  /// Logs a caught exception at [LogLevel.error] with a stable fingerprint,
  /// normalized stack frames and (if enabled) its causal chain.
  void error(
    Object error,
    StackTrace? stackTrace, {
    String? message,
    Map<String, Object?>? context,
    List<String>? tags,
  }) =>
      errorEvent(error, stackTrace,
          message: message, context: context, tags: tags);

  /// Logs a caught exception at [LogLevel.fatal].
  void fatal(
    Object error,
    StackTrace? stackTrace, {
    String? message,
    Map<String, Object?>? context,
    List<String>? tags,
  }) =>
      errorEvent(
        error,
        stackTrace,
        message: message,
        context: context,
        tags: tags,
        level: LogLevel.fatal,
      );

  /// Shared implementation behind [error], [fatal] and [Span.fail].
  void errorEvent(
    Object errorObject,
    StackTrace? stackTrace, {
    String? message,
    Map<String, Object?>? context,
    List<String>? tags,
    LogLevel level = LogLevel.error,
    int? durationMs,
  }) {
    final info = ErrorInfo.from(
      errorObject,
      stackTrace,
      sanitizeText: _core.sanitizer.sanitizeText,
    );
    _emit(
      level,
      message ?? info.message,
      context: context,
      tags: tags,
      error: info,
      durationMs: durationMs,
    );
  }

  /// Logs a pre-built [ErrorInfo] rather than a Dart exception object.
  ///
  /// Use this when an error originates outside Dart — most commonly a
  /// native (iOS/Android) exception forwarded over a platform channel,
  /// where the type/message/frames already arrived as plain strings and
  /// there is no Dart [StackTrace] to run through [ErrorInfo.from]. Prefer
  /// [error]/[fatal] for anything caught in Dart code.
  ///
  /// [info]'s message and frames are still redacted through this logger's
  /// [Redactor] before being emitted.
  void logError(
    ErrorInfo info, {
    String? message,
    Map<String, Object?>? context,
    List<String>? tags,
    LogLevel level = LogLevel.error,
    int? durationMs,
  }) {
    final sanitizer = _core.sanitizer;
    ErrorInfo sanitize(ErrorInfo source) => ErrorInfo(
          type: source.type,
          message: sanitizer.sanitizeText(source.message),
          fingerprint: source.fingerprint,
          frames: source.frames.map(sanitizer.sanitizeText).toList(),
          cause: source.cause == null ? null : sanitize(source.cause!),
        );

    final sanitized = sanitize(info);
    _emit(
      level,
      message ?? sanitized.message,
      context: context,
      tags: tags,
      error: sanitized,
      durationMs: durationMs,
    );
  }

  /// Logs at [level]. A null [message] makes this a checkpoint — see
  /// [checkpoint].
  void log(
    LogLevel level,
    String? message, {
    Map<String, Object?>? context,
    List<String>? tags,
    int? durationMs,
  }) =>
      _emit(
        level,
        message,
        context: context,
        tags: tags,
        durationMs: durationMs,
      );

  // --- Core emission ---------------------------------------------------

  void _emit(
    LogLevel level,
    String? message, {
    Map<String, Object?>? context,
    List<String>? tags,
    ErrorInfo? error,
    int? durationMs,
  }) {
    if (!level.passes(_core.minimumLevel)) return;

    final scope = currentScope;
    final mergedContext = {...scope.fields, ...?context};
    final mergedTags = [...scope.tags, ...?tags];

    // A message-less call is a checkpoint: synthesize one from the call site
    // so the line still says *where* execution reached. Capturing the stack
    // is only paid here — after the level filter — so checkpoints below
    // `minimumLevel` cost nothing.
    var resolvedMessage = message;
    if (resolvedMessage == null) {
      resolvedMessage = captureCallSite()?.render() ?? '';
      mergedTags.add('checkpoint');
    }

    final event = LogEvent(
      time: DateTime.now(),
      level: level,
      // Redact *and* bound the message. Without the length bound a single
      // `logger.info(hugeString)` could put megabytes on one line and eat an
      // entire model context window — the same budget guarantee `Sanitizer`
      // makes for context values applies here.
      message: _core.sanitizer.sanitizeText(resolvedMessage),
      logger: name,
      sessionId: _core.sessionId,
      sequence: _core.sequence.next(),
      traceId: scope.traceId,
      spanId: scope.spanId,
      parentSpanId: scope.parentSpanId,
      context: _core.sanitizer.sanitizeMap(mergedContext),
      tags: mergedTags,
      error: error,
      durationMs: durationMs,
    );

    final withChain = _attachCausalChain(event,
        isErrorish: error != null || level.severity >= LogLevel.error.severity);
    _core.causalBuffer.record(event);
    _core.sink.add(withChain);
  }

  LogEvent _attachCausalChain(LogEvent event, {required bool isErrorish}) {
    if (!isErrorish || _core.causalChainLength <= 0) return event;
    final chain =
        _core.causalBuffer.chainFor(event, limit: _core.causalChainLength);
    if (chain.isEmpty) return event;
    return LogEvent(
      time: event.time,
      level: event.level,
      message: event.message,
      logger: event.logger,
      sessionId: event.sessionId,
      sequence: event.sequence,
      traceId: event.traceId,
      spanId: event.spanId,
      parentSpanId: event.parentSpanId,
      context: event.context,
      tags: event.tags,
      error: event.error,
      durationMs: event.durationMs,
      chain: chain,
    );
  }

  Future<void> flush() => _core.sink.flush();

  Future<void> close() => _core.sink.close();
}
