/// The wire format: one JSON object per line.
///
/// Keys are short on purpose. A log file is read by a model far more often
/// than by a human, and `"ts"` instead of `"timestamp"` across a million lines
/// is a measurable slice of a context window. [schemaLegend] ships the key
/// meanings in the file itself, so no external documentation is needed to
/// interpret it.
library;

import 'log_level.dart';
import 'normalizer.dart';

/// Version of the on-disk format. Bumped on any breaking key change.
const int aiLogSchemaVersion = 1;

/// Human/model readable description of every key, written as the first line
/// of each JSONL file.
Map<String, Object?> schemaLegend() => {
      'ts': 'ISO-8601 UTC timestamp',
      'lvl': 'trace|debug|info|warn|error|fatal',
      'msg': 'log message',
      'lg': 'logger name (subsystem)',
      'ses': 'session id: one process run',
      'tr': 'trace id: one logical operation (request, tap, job)',
      'sp': 'span id within the trace',
      'psp': 'parent span id',
      'seq': 'monotonic sequence number within one writer (one "ses"); '
          'restores exact order for events sharing a ses, but is NOT '
          'comparable across different ses values in the same file',
      'dur': 'duration in ms (span completion events)',
      'tags': 'free-form labels',
      'ctx': 'structured context, secrets already masked',
      'err': 'error: t=type, m=message, fp=fingerprint (group key), '
          'fr=stack frames (app frames first), cause=nested cause',
      'chain': 'causal chain: events that preceded this error in the same '
          'trace. dt=ms before the error (negative)',
      // Not a key — a convention, described here because a reader meeting
      // `[redacted:email#892c8bf7]` for the first time needs to know the
      // hash is stable. Prefixed so it cannot be mistaken for a field to
      // look up on an event.
      '_convention:redacted':
          'masked values appear as [redacted:kind#hash] in any field; equal '
              'hash means equal original value within this file',
    };

/// Structured description of a thrown object.
class ErrorInfo {
  /// Creates an [ErrorInfo] from already-computed parts.
  ///
  /// Prefer [ErrorInfo.from], which derives all of them from a caught object
  /// and its stack trace. This constructor exists for callers that already
  /// have the pieces — the native bridge in `ailog_flutter`, which receives
  /// them over a MethodChannel, and [fromJson] when reading a file back.
  ErrorInfo({
    required this.type,
    required this.message,
    required this.fingerprint,
    this.frames = const [],
    this.cause,
  });

  /// Runtime type of the thrown object, e.g. `SocketException`.
  final String type;

  /// The thrown object's `toString()`, after redaction.
  ///
  /// Unlike [fingerprint] this still contains the varying parts — the host
  /// that refused the connection, the id that was not found — which is what
  /// makes it worth reading once the fingerprint has told you which bug it is.
  final String message;

  /// Stable grouping key. Same bug, same fingerprint.
  final String fingerprint;

  /// Normalized stack frames, application frames first.
  final List<String> frames;

  /// Nested cause, when the error wraps another one.
  final ErrorInfo? cause;

  /// The `err` object as it appears on the wire: `t`, `m`, `fp`, `fr`,
  /// `cause`. Empty frames and a null cause are omitted rather than written
  /// as empty values, so a line costs nothing for what it does not have.
  Map<String, Object?> toJson() => {
        't': type,
        'm': message,
        'fp': fingerprint,
        if (frames.isNotEmpty) 'fr': frames,
        if (cause != null) 'cause': cause!.toJson(),
      };

  /// Reads back an `err` object written by [toJson], recursing into `cause`.
  ///
  /// Returns `null` for anything that is not a map, so a caller can pass
  /// `json['err']` straight in without checking whether the key was present.
  /// Missing fields fall back to `'Error'` / `''` rather than throwing: a
  /// tool reading a log file should degrade, not abort on one bad line.
  static ErrorInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    return ErrorInfo(
      type: json['t']?.toString() ?? 'Error',
      message: json['m']?.toString() ?? '',
      fingerprint: json['fp']?.toString() ?? '',
      frames:
          (json['fr'] as List?)?.map((f) => f.toString()).toList() ?? const [],
      cause: ErrorInfo.fromJson(json['cause']),
    );
  }

  /// Builds an [ErrorInfo] from a caught object.
  ///
  /// [maxFrames] bounds how much stack survives; the frames that identify a
  /// bug are almost always the first few application ones.
  factory ErrorInfo.from(
    Object error,
    StackTrace? stackTrace, {
    int maxFrames = 12,
    String Function(String)? sanitizeText,
  }) {
    final type = error.runtimeType.toString();
    // `toString()` on a thrown object is caller code and can itself throw —
    // a buggy override, an uninitialized `late` field, a getter that fails.
    // Unguarded, that turned `logger.error(e, st)` into a second, different
    // crash while trying to record the first one.
    String rawMessage;
    try {
      rawMessage = error.toString();
    } catch (thrown) {
      rawMessage = '<$type.toString() threw ${thrown.runtimeType}>';
    }
    final message = sanitizeText?.call(rawMessage) ?? rawMessage;

    // Parsed once and used for both the displayed frames and the
    // fingerprint. Parsing twice — which is what calling `errorFingerprint`
    // here would do — was over half the cost of logging an error, and that
    // cost lands exactly during an error storm.
    final parsed = parseStackTrace(stackTrace, maxFrames: 40);
    // Application frames carry the signal; SDK frames are kept only as filler
    // when there is room left.
    final appFrames = parsed.where((f) => f.isApp).toList();
    final otherFrames = parsed.where((f) => !f.isApp).toList();
    final ordered = [...appFrames, ...otherFrames].take(maxFrames);

    return ErrorInfo(
      type: type,
      message: message,
      fingerprint: errorFingerprintFromParsedFrames(
        errorType: type,
        message: rawMessage,
        frames: parsed,
      ),
      frames: ordered.map((f) => f.render()).toList(),
    );
  }
}

/// A single log record.
class LogEvent {
  /// Creates a log record directly.
  ///
  /// Application code does not normally call this — `Logger`'s level methods
  /// build the event, fill in [sessionId] and [sequence], pick up the
  /// ambient trace, and redact [context] before any sink sees it. Construct
  /// one by hand only when feeding a `LogSink` from somewhere other than a
  /// `Logger`, and remember that nothing sanitizes what you pass here.
  LogEvent({
    required this.time,
    required this.level,
    required this.message,
    required this.logger,
    required this.sessionId,
    required this.sequence,
    this.traceId,
    this.spanId,
    this.parentSpanId,
    this.context = const {},
    this.tags = const [],
    this.error,
    this.durationMs,
    this.chain = const [],
  });

  /// When the event was recorded. Serialized to `ts` as ISO-8601 **UTC**,
  /// so lines from devices in different time zones sort against each other.
  final DateTime time;

  /// Severity (`lvl`). See [LogLevel] for what each one is for.
  final LogLevel level;

  /// The message (`msg`), after redaction.
  final String message;

  /// Which subsystem emitted this (`lg`) — `'app'` unless the event came
  /// from a `logger.child('db')`. Groups a file by area without needing
  /// separate files per subsystem.
  final String logger;

  /// Identifies one process run (`ses`). Constant for the life of a
  /// `Logger`, and regenerated on the next start.
  ///
  /// It is what makes a rotated or concatenated file interpretable: two
  /// events with different `ses` values came from different runs, however
  /// close their timestamps are.
  final String sessionId;

  /// Monotonic counter within one [sessionId] (`seq`), starting at 1.
  ///
  /// Restores exact order for events that share a session even when their
  /// timestamps collide, and — because it has no gaps by construction —
  /// lets a reader compute how many events are *missing* from a file that
  /// rotation truncated. `Digest` reports exactly that.
  ///
  /// Not comparable across different [sessionId] values.
  final int sequence;

  /// The trace this event belongs to (`tr`), or `null` outside any scope.
  ///
  /// One trace = one logical operation: a request, a tap, a background job.
  /// Set automatically from the ambient `LogScope`; see `runWithScope`.
  final String? traceId;

  /// The span within [traceId] this event belongs to (`sp`), or `null`.
  final String? spanId;

  /// The enclosing span (`psp`), for nested spans. Lets a reader rebuild the
  /// tree of steps from flat lines.
  final String? parentSpanId;

  /// Structured fields (`ctx`) — already redacted by the time an event
  /// exists. Merged from the ambient scope's context and the call's own,
  /// with the call's winning on a key collision.
  final Map<String, Object?> context;

  /// Free-form labels (`tags`). The package sets `print` on captured
  /// `print()` output and `interaction` on `logger.interaction()` calls.
  final List<String> tags;

  /// The error this event describes (`err`), or `null` for a plain message.
  final ErrorInfo? error;

  /// How long the completed span took, in milliseconds (`dur`). Only set on
  /// span-completion events.
  final int? durationMs;

  /// Events that preceded this one in the same trace. Only populated for
  /// error-ish levels; see `CausalBuffer`.
  final List<Map<String, Object?>> chain;

  /// The event as one JSON object — exactly the shape `JsonlFileSink` writes
  /// as a line.
  ///
  /// Optional keys are omitted when empty rather than emitted as `null`,
  /// which is most of why a line stays small. `schemaLegend` documents every
  /// key, and is written as the first line of each file so the format
  /// explains itself to whoever (or whatever) reads it.
  Map<String, Object?> toJson() => {
        'ts': time.toUtc().toIso8601String(),
        'lvl': level.wireName,
        'msg': message,
        'lg': logger,
        'ses': sessionId,
        'seq': sequence,
        if (traceId != null) 'tr': traceId,
        if (spanId != null) 'sp': spanId,
        if (parentSpanId != null) 'psp': parentSpanId,
        if (durationMs != null) 'dur': durationMs,
        if (tags.isNotEmpty) 'tags': tags,
        if (context.isNotEmpty) 'ctx': context,
        if (error != null) 'err': error!.toJson(),
        if (chain.isNotEmpty) 'chain': chain,
      };

  /// Parses a line previously written by this package. Returns `null` for
  /// header lines and anything unparseable, so tools can just skip them.
  static LogEvent? fromJson(Map<String, Object?> json) {
    final level = LogLevel.tryParse(json['lvl'] as String?);
    final timestamp = DateTime.tryParse(json['ts'] as String? ?? '');
    if (level == null || timestamp == null) return null;
    return LogEvent(
      time: timestamp,
      level: level,
      message: json['msg']?.toString() ?? '',
      logger: json['lg']?.toString() ?? 'app',
      sessionId: json['ses']?.toString() ?? '',
      sequence: (json['seq'] as num?)?.toInt() ?? 0,
      traceId: json['tr'] as String?,
      spanId: json['sp'] as String?,
      parentSpanId: json['psp'] as String?,
      context: (json['ctx'] as Map?)?.cast<String, Object?>() ?? const {},
      tags: (json['tags'] as List?)?.map((t) => t.toString()).toList() ??
          const [],
      error: ErrorInfo.fromJson(json['err']),
      durationMs: (json['dur'] as num?)?.toInt(),
      chain: (json['chain'] as List?)
              ?.whereType<Map>()
              .map((e) => e.cast<String, Object?>())
              .toList() ??
          const [],
    );
  }

  /// The compact form embedded in another event's causal chain.
  ///
  /// [relativeTo] turns the absolute timestamp into `dt`, a negative
  /// millisecond offset, which is both shorter and easier to reason about
  /// ("the timeout fired 1.2s before the crash").
  Map<String, Object?> toChainEntry(DateTime relativeTo) => {
        'dt': time.difference(relativeTo).inMilliseconds,
        'lvl': level.wireName,
        'msg': message,
        if (logger != 'app') 'lg': logger,
        if (context.isNotEmpty) 'ctx': context,
      };
}
