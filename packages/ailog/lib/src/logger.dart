/// The public entry point: create one [Logger], derive children from it.
library;

import 'dart:async';

import 'breadcrumb.dart';
import 'build_mode.dart';
import 'call_site.dart';
import 'causal_buffer.dart';
import 'context.dart';
import 'ids.dart';
import 'log_event.dart';
import 'log_level.dart';
import 'platform.dart';
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
    required this.enabled,
    required this.minimumLevel,
    required this.breadcrumbLevel,
    required this.sessionId,
    required this.causalChainLength,
    required int causalChainTraces,
    required this.baseContext,
    IdGenerator? idGenerator,
  })  : idGenerator = idGenerator ?? IdGenerator(),
        sequence = SequenceCounter(),
        causalBuffer = CausalBuffer(
          perTraceCapacity: causalChainLength,
          maxTraces: causalChainTraces,
        );

  final LogSink sink;
  final Sanitizer sanitizer;

  /// When false, every log call returns immediately. See [Logger.create].
  final bool enabled;

  /// Minimum level that reaches [sink].
  final LogLevel minimumLevel;

  /// Minimum level retained as a breadcrumb for causal chains. Always at or
  /// below [minimumLevel].
  final LogLevel breadcrumbLevel;

  final String sessionId;
  final int causalChainLength;

  /// Fields merged into every event, ahead of scope and call-site fields.
  final Map<String, Object?> baseContext;

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
  Logger._(this._core, this.name, this._clock);

  final _LoggerCore _core;

  /// Injectable time source, so tests can assert against exact output.
  final DateTime Function() _clock;

  /// Subsystem name, written as `lg` in every event.
  final String name;

  /// Creates a root logger.
  ///
  /// [sink] is where events go; combine sinks with [MultiSink] for "file +
  /// console". [redactor] controls automatic masking — pass
  /// `Redactor.disabled()` only for local, throwaway debugging.
  ///
  /// [minimumLevel] is what reaches [sink]. [breadcrumbLevel] is what is
  /// retained for causal chains, and defaults to [LogLevel.trace] — *below*
  /// `minimumLevel` on purpose.
  ///
  /// That split is the whole point of the causal chain. Breadcrumbs are
  /// naturally `debug`/`trace` ("cache hit", "session age 610s"), so if the
  /// buffer only saw what was emitted, shipping the usual
  /// `minimumLevel: info` would leave every chain containing nothing but
  /// other info lines already three rows up in the file. Keeping them
  /// separate means an error still arrives with the low-level detail that
  /// explains it, while the file stays quiet.
  ///
  /// The cost is that events between `breadcrumbLevel` and `minimumLevel` are
  /// still built and sanitized, just not written. If a hot path makes that
  /// matter, raise `breadcrumbLevel` (setting it equal to `minimumLevel`
  /// restores buffer-only-what-you-emit) or set [causalChainLength] to `0` to
  /// switch chains off entirely.
  ///
  /// [causalChainLength] bounds how many preceding events attach to each
  /// error; [causalChainTraces] bounds how many traces are tracked at once —
  /// raise it on a server handling many concurrent requests, since traces
  /// beyond the bound lose their breadcrumbs.
  ///
  /// [baseContext] is merged into every event this logger and its children
  /// emit — app version, build number, environment, user id. Unlike a trace
  /// scope it needs no `runWithScope`, so it also covers timers, isolates and
  /// anything logged before a zone is entered. Call-site and scope fields win
  /// on key collision.
  ///
  /// [includePlatformContext] merges OS, Dart version, pid and locale into
  /// every event. **Usually you do not want this**: [JsonlFileSink] already
  /// writes the same facts into each file's `_hdr` line, once, and they do
  /// not change between events. Measured on a 100-event file, merging them
  /// per event grew it 73% — 182 to 315 bytes per line. That dwarfs
  /// everything the short key names save. Turn it on when events from
  /// several machines are merged into one stream and the platform genuinely
  /// varies line to line.
  ///
  /// [enabled] switches the whole logger off: every call returns before any
  /// formatting, sanitizing or sink work.
  ///
  /// **It defaults to `!isReleaseBuild`, so a release build logs nothing
  /// unless you ask it to.** Writing a user's device full of diagnostics is
  /// not something a package should start doing because you added a
  /// dependency; it should be a decision you made. Debug and profile builds
  /// are unaffected and log normally.
  ///
  /// Opting a release build back in is one argument:
  ///
  /// ```dart
  /// Logger.create(sink: sink, enabled: true);                  // always
  /// Logger.create(sink: sink, enabled: userOptedIntoDiagnostics);
  /// ```
  ///
  /// Know what you are turning off if you leave the default. Production is
  /// where the failures you cannot reproduce live, and this package exists
  /// to make those analyzable — a release build that logs nothing cannot
  /// describe them. Pair `enabled: true` with a raised [minimumLevel] when
  /// the worry is volume rather than the existence of the file:
  ///
  /// ```dart
  /// Logger.create(
  ///   sink: sink,
  ///   enabled: true,
  ///   minimumLevel: byBuildMode(debug: LogLevel.trace, release: LogLevel.info),
  /// );
  /// ```
  ///
  /// Leaving it off still costs a branch per call (measured at 5 ns in a
  /// release AOT build). [Logger.disabled] behind a `const` condition lets
  /// the compiler remove the sink's construction outright.
  ///
  /// [idGenerator] and [clock] are injectable so tests can pin ids and
  /// timestamps and assert against exact output.
  factory Logger.create({
    required LogSink sink,
    String name = 'app',
    // A release build stays silent unless the caller opts in. `isReleaseBuild`
    // is a compile-time constant, so this is a valid const default and folds
    // away rather than being evaluated per construction.
    bool enabled = !isReleaseBuild,
    LogLevel minimumLevel = LogLevel.trace,
    LogLevel breadcrumbLevel = LogLevel.trace,
    Redactor? redactor,
    SanitizerLimits limits = const SanitizerLimits(),
    int causalChainLength = 10,
    int causalChainTraces = 64,
    Map<String, Object?>? baseContext,
    bool includePlatformContext = false,
    String? sessionId,
    IdGenerator? idGenerator,
    DateTime Function()? clock,
  }) {
    final core = _LoggerCore(
      sink: sink,
      sanitizer: Sanitizer(redactor: redactor, limits: limits),
      enabled: enabled,
      minimumLevel: minimumLevel,
      // Never above minimumLevel: a level that isn't emitted but also isn't
      // buffered would just be dropped, which no caller can want.
      breadcrumbLevel: breadcrumbLevel.severity <= minimumLevel.severity
          ? breadcrumbLevel
          : minimumLevel,
      sessionId: sessionId ?? IdGenerator().traceId(),
      causalChainLength: causalChainLength,
      causalChainTraces: causalChainTraces,
      baseContext: {
        if (includePlatformContext) ...platformContext(),
        ...?baseContext,
      },
      idGenerator: idGenerator,
    );
    return Logger._(core, name, clock ?? DateTime.now);
  }

  /// A logger that does nothing.
  ///
  /// Every call returns immediately, and no sink is involved — which is the
  /// point when combined with [isReleaseBuild], because the branch is
  /// const-folded and the AOT compiler drops the real sink's construction
  /// along with it:
  ///
  /// ```dart
  /// final logger = isReleaseBuild
  ///     ? Logger.disabled()
  ///     : Logger.create(sink: JsonlFileSink(path: logPath));
  /// ```
  ///
  /// Worth pausing before you do that, though. This package exists to make
  /// *post-mortem* analysis possible, and the failures worth analyzing are
  /// the ones users hit in production — which a release build with no
  /// logging cannot describe. Raising [minimumLevel] in release keeps the
  /// evidence while cutting the volume:
  ///
  /// ```dart
  /// minimumLevel: byBuildMode(debug: LogLevel.trace, release: LogLevel.info)
  /// ```
  ///
  /// Turning it off entirely is the right call when the log would contain
  /// data you are not willing to store on a user's device, or when the build
  /// ships to somewhere you can never retrieve a file from. Those are real;
  /// "release builds should be fast" usually is not, given a filtered-out
  /// call costs a single bool test.
  factory Logger.disabled({String name = 'app'}) => Logger.create(
        sink: const _NullSink(),
        name: name,
        enabled: false,
        causalChainLength: 0,
      );

  /// A logger backed by [MemorySink], useful for tests.
  factory Logger.forTesting({
    MemorySink? sink,
    LogLevel minimumLevel = LogLevel.trace,
    LogLevel breadcrumbLevel = LogLevel.trace,
    Redactor? redactor,
    IdGenerator? idGenerator,
    DateTime Function()? clock,
  }) =>
      Logger.create(
        sink: sink ?? MemorySink(),
        // Explicit, not inherited from the build mode. A test compiled AOT
        // would otherwise get a silently disabled logger and assertions that
        // fail for a reason nowhere near the test.
        enabled: true,
        minimumLevel: minimumLevel,
        breadcrumbLevel: breadcrumbLevel,
        redactor: redactor ?? Redactor.disabled(),
        sessionId: 'test-session',
        idGenerator: idGenerator,
        clock: clock,
      );

  /// Derives a child logger for a named subsystem, sharing this logger's sink,
  /// session and causal buffer.
  Logger child(String name) => Logger._(_core, name, _clock);

  /// The current time, from this logger's clock. Used by [Span] so span
  /// durations honor an injected clock too.
  DateTime now() => _clock();

  /// Whether an event at [level] would reach the sink.
  ///
  /// Guard expensive call sites with this — building a context map costs the
  /// same whether or not the event is ultimately written:
  ///
  /// ```dart
  /// if (logger.isEnabled(LogLevel.debug)) {
  ///   logger.debug('state', context: {'graph': graph.toDebugMap()});
  /// }
  /// ```
  ///
  /// Note this returns false for levels that are still retained as
  /// breadcrumbs — see [Logger.create]'s `breadcrumbLevel`. Use
  /// [isRecorded] if you want to know whether the event has any effect at
  /// all.
  bool isEnabled(LogLevel level) =>
      _core.enabled && level.passes(_core.minimumLevel);

  /// Whether an event at [level] would be either emitted or retained as a
  /// breadcrumb — i.e. whether logging it does anything at all.
  bool isRecorded(LogLevel level) =>
      _core.enabled &&
      (level.passes(_core.minimumLevel) ||
          (_core.causalChainLength > 0 && level.passes(_core.breadcrumbLevel)));

  /// The level at or above which events reach the sink.
  LogLevel get minimumLevel => _core.minimumLevel;

  /// Identifies this process run. Written as `ses` on every event, and
  /// shared with any child logger.
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
  ///
  /// **This only creates the span; it does not install its scope.** Anything
  /// logged between here and [Span.succeed]/[Span.fail] comes out with no
  /// trace or span id unless you wrap it yourself:
  ///
  /// ```dart
  /// final span = logger.startSpan('upload');
  /// await runWithScope(span.scope, () async { ... });
  /// span.succeed();
  /// ```
  ///
  /// Prefer [span] or [spanSync], which do that wrapping and also close the
  /// span on both return and throw. Reach for this form only when the work
  /// genuinely isn't a single callback.
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
  // `message` is deliberately non-nullable. An earlier version accepted
  // `String?` so `logger.info(null)` could double as a checkpoint, but that
  // made `logger.info(response.errorMessage)` — where the value is a
  // `String?` — silently turn into a checkpoint instead of logging what the
  // caller asked for, with no analyzer warning. [checkpoint] is the explicit
  // way to log a call site.
  //

  /// Logs at [LogLevel.trace] — fine-grained detail.
  ///
  /// Usually below a production `minimumLevel`, but still recorded as a
  /// breadcrumb, so these reappear in the causal chain of a later error.
  void trace(
    String message, {
    Map<String, Object?>? context,
    List<String>? tags,
  }) =>
      log(LogLevel.trace, message, context: context, tags: tags);

  /// Logs at [LogLevel.debug] — developer-facing detail.
  void debug(
    String message, {
    Map<String, Object?>? context,
    List<String>? tags,
  }) =>
      log(LogLevel.debug, message, context: context, tags: tags);

  /// Logs at [LogLevel.info] — something the program did that a reader would
  /// want to know about. The usual production floor.
  void info(
    String message, {
    Map<String, Object?>? context,
    List<String>? tags,
  }) =>
      log(LogLevel.info, message, context: context, tags: tags);

  /// Logs at [LogLevel.warn] — recovered from, but suspicious.
  void warn(
    String message, {
    Map<String, Object?>? context,
    List<String>? tags,
  }) =>
      log(LogLevel.warn, message, context: context, tags: tags);

  /// Logs a message at [LogLevel.error]. For a caught exception, prefer
  /// [error] so the fingerprint and stack frames are captured.
  void errorMessage(
    String message, {
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
  /// or higher keeps checkpoints out of the file while still retaining them
  /// as breadcrumbs for causal chains.
  ///
  /// [skipFrames] walks further down the stack before picking a frame. Pass
  /// `1` when calling from a wrapper, so the checkpoint reports *your*
  /// caller rather than the wrapper itself:
  ///
  /// ```dart
  /// class AppLog {
  ///   void mark() => _logger.checkpoint(skipFrames: 1);
  /// }
  /// ```
  ///
  /// **Reliability**: resolving a call site means parsing
  /// `StackTrace.current`, which is not available in every build. Release
  /// builds using `--obfuscate`/`--split-debug-info` produce non-symbolic
  /// traces, and some browsers emit formats Dart cannot map back. When the
  /// call site can't be resolved the message says so explicitly rather than
  /// being blank — see [checkpointsResolveCallSites] to detect that at
  /// startup.
  void checkpoint({
    LogLevel level = LogLevel.trace,
    Map<String, Object?>? context,
    List<String>? tags,
    int skipFrames = 0,
  }) =>
      _emit(
        level,
        null,
        context: context,
        tags: tags,
        skipFrames: skipFrames,
      );

  /// Records something the *user* did — a tap, a swipe, a form submission.
  ///
  /// "What was the user doing just before this crash" is the single most
  /// useful thing a bug report can carry, and this package already has the
  /// mechanism for it: at the default [LogLevel.trace], interactions stay
  /// out of a production file but are retained as breadcrumbs, so they turn
  /// up embedded in the causal chain of whatever failed next:
  ///
  /// ```text
  /// ERROR checkout failed [fp:7ed4a8d1]
  ///   — causal chain —
  ///     -8.2s  ▸ tapped "View cart"
  ///     -5.1s  route pushed: /cart
  ///     -0.3s  ▸ tapped "Pay now"
  /// ```
  ///
  /// Pass the *intent*, not the button's caption:
  ///
  /// ```dart
  /// logger.interaction('checkout_pressed', context: {'items': 3});
  /// ```
  ///
  /// An intent name survives copy changes, translation and A/B tests, and it
  /// groups across all of them. A caption ("Pay now" / "支払う") splits one
  /// behaviour into as many buckets as you have locales.
  ///
  /// The `▸` prefix and the `interaction` tag make these trivially separable
  /// from application logging — `logger.interaction` events answer "what did
  /// the person do", everything else answers "what did the program do".
  void interaction(
    String name, {
    LogLevel level = LogLevel.trace,
    Map<String, Object?>? context,
    List<String>? tags,
  }) =>
      _emit(
        level,
        '▸ $name',
        context: context,
        tags: [...?tags, 'interaction'],
      );

  /// Whether [checkpoint] can resolve call sites in this build.
  ///
  /// False in non-symbolic AOT builds and on some web targets. Check it once
  /// at startup and warn, rather than discovering during an incident that
  /// every checkpoint in the file says the call site was unavailable:
  ///
  /// ```dart
  /// if (!Logger.checkpointsResolveCallSites()) {
  ///   logger.warn('checkpoints cannot resolve call sites in this build');
  /// }
  /// ```
  static bool checkpointsResolveCallSites() => captureCallSite() != null;

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
    int skipFrames = 0,
  }) {
    // Ahead of everything: no formatting, no sanitizing, no breadcrumb, no
    // stack capture. One bool test is the entire cost of a disabled logger.
    if (!_core.enabled) return;
    final emitting = level.passes(_core.minimumLevel);
    // Events below `minimumLevel` are still kept as breadcrumbs so an error's
    // causal chain has the low-level detail that explains it. See
    // [Logger.create].
    final buffering =
        _core.causalChainLength > 0 && level.passes(_core.breadcrumbLevel);
    if (!emitting && !buffering) return;

    final scope = currentScope;
    final now = _clock();

    // A message-less call is a checkpoint: synthesize one from the call site
    // so the line still says *where* execution reached. Only paid once we
    // know the event is going somewhere.
    var resolvedMessage = message;
    var isCheckpoint = false;
    if (resolvedMessage == null) {
      resolvedMessage = captureCallSite(skipFrames: skipFrames)?.render() ??
          _unresolvedCallSite;
      isCheckpoint = true;
    }

    // Precedence, least to most specific: base < scope < call site.
    final mergedContext = _core.baseContext.isEmpty &&
            scope.fields.isEmpty &&
            (context == null || context.isEmpty)
        ? const <String, Object?>{}
        : <String, Object?>{
            ..._core.baseContext,
            ...scope.fields,
            ...?context,
          };

    // Chain first, breadcrumb second: an event must not appear in its own
    // causal chain.
    final isErrorish =
        error != null || level.severity >= LogLevel.error.severity;
    final chain = emitting && isErrorish && _core.causalChainLength > 0
        ? _core.causalBuffer.chainFor(
            time: now,
            traceId: scope.traceId,
            sanitizer: _core.sanitizer,
            limit: _core.causalChainLength,
          )
        : const <Map<String, Object?>>[];

    if (buffering) {
      // Recorded raw. Most breadcrumbs are never rendered — they only become
      // visible if an error happens in the same trace while they are still in
      // the buffer — so redaction and the recursive sanitize walk are
      // deferred to render time. Doing them here would make a filtered-out
      // `logger.debug()` cost as much as an emitted one, which would defeat
      // the point of setting `minimumLevel` at all.
      _core.causalBuffer.record(
        Breadcrumb(
          time: now,
          level: level,
          message: resolvedMessage,
          logger: name,
          context: mergedContext,
        ),
        traceId: scope.traceId,
      );
    }
    if (!emitting) return;

    final mergedTags = [
      ...scope.tags,
      ...?tags,
      if (isCheckpoint) 'checkpoint',
    ];

    _core.sink.add(
      LogEvent(
        time: now,
        level: level,
        // Redact *and* bound the message. Without the length bound a single
        // `logger.info(hugeString)` could put megabytes on one line and eat
        // an entire model context window — the same budget guarantee
        // `Sanitizer` makes for context values applies here.
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
        chain: chain,
      ),
    );
  }

  /// Stands in for a call site that could not be resolved.
  ///
  /// Non-symbolic AOT stack traces (`--obfuscate`/`--split-debug-info`) and
  /// some browser trace formats yield nothing parseable. Emitting an empty
  /// message there would leave a blank line that looks like a bug in the
  /// caller; this at least says what happened and why.
  static const String _unresolvedCallSite =
      '→ <call site unavailable: obfuscated or non-symbolic build>';

  /// Pushes anything buffered in the sink to its destination.
  ///
  /// **Not enough on its own to end a program.** `JsonlFileSink` runs a
  /// periodic timer to auto-flush, and a live timer keeps the isolate alive
  /// — so a `main()` that flushes and returns hangs instead of exiting. Call
  /// [close].
  Future<void> flush() => _core.sink.flush();

  /// Flushes, then releases the sink and everything it holds open.
  ///
  /// This is the one to call before a process ends. The logger is unusable
  /// afterwards: further calls reach a closed sink.
  Future<void> close() => _core.sink.close();
}

/// The sink for [Logger.disabled]: it can never be reached, because the
/// logger returns before touching it. It exists so `Logger.disabled()` needs
/// no allocation and no import of a real sink.
class _NullSink implements LogSink {
  const _NullSink();

  @override
  void add(LogEvent event) {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}
