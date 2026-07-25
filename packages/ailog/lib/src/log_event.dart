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
      'redacted': 'values shown as [redacted:kind#hash]; equal hash means '
          'equal original value within this file',
    };

/// Structured description of a thrown object.
class ErrorInfo {
  ErrorInfo({
    required this.type,
    required this.message,
    required this.fingerprint,
    this.frames = const [],
    this.cause,
  });

  /// Runtime type of the thrown object, e.g. `SocketException`.
  final String type;
  final String message;

  /// Stable grouping key. Same bug, same fingerprint.
  final String fingerprint;

  /// Normalized stack frames, application frames first.
  final List<String> frames;

  /// Nested cause, when the error wraps another one.
  final ErrorInfo? cause;

  Map<String, Object?> toJson() => {
        't': type,
        'm': message,
        'fp': fingerprint,
        if (frames.isNotEmpty) 'fr': frames,
        if (cause != null) 'cause': cause!.toJson(),
      };

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

  final DateTime time;
  final LogLevel level;
  final String message;
  final String logger;
  final String sessionId;
  final int sequence;
  final String? traceId;
  final String? spanId;
  final String? parentSpanId;
  final Map<String, Object?> context;
  final List<String> tags;
  final ErrorInfo? error;
  final int? durationMs;

  /// Events that preceded this one in the same trace. Only populated for
  /// error-ish levels; see `CausalBuffer`.
  final List<Map<String, Object?>> chain;

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
