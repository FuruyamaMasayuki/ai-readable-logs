/// Structured JSONL logging designed to be read by an AI.
///
/// A zero-dependency, pure Dart package providing trace/session correlation,
/// causal chains embedded in error lines, error fingerprinting and grouping,
/// automatic secret redaction, and AI-sized digest generation.
library ailog;

export 'src/breadcrumb.dart' show Breadcrumb;
export 'src/build_mode.dart'
    show
        BuildMode,
        byBuildMode,
        currentBuildMode,
        isDebugBuild,
        isProfileBuild,
        isReleaseBuild;
export 'src/call_site.dart' show CallSite, captureCallSite;
export 'src/causal_buffer.dart' show CausalBuffer;
export 'src/console_formatter.dart' show ConsoleFormatter;
export 'src/context.dart'
    show LogScope, currentScope, runWithScope, runWithScopeGuarded;
export 'src/digest.dart'
    show Digest, DigestBuilder, ErrorGroup, MessageShape, NumericField;
export 'src/export.dart'
    show LogFilter, LogSelection, buildDigest, digestFromJsonl;
export 'src/ids.dart' show IdGenerator, SequenceCounter, fnv1a64Hex, shortHash;
export 'src/log_event.dart'
    show LogEvent, ErrorInfo, aiLogSchemaVersion, schemaLegend;
export 'src/log_level.dart' show LogLevel;
export 'src/logger.dart';
export 'src/print_capture.dart' show capturePrints;
export 'src/normalizer.dart'
    show
        StackFrame,
        parseStackTrace,
        normalizeMessage,
        errorFingerprint,
        errorFingerprintFromFrames;
export 'src/redaction.dart'
    show
        Redactor,
        RedactionRule,
        builtInRedactionRules,
        defaultSensitiveKeyPattern,
        sensitiveKeyWords;
export 'src/sanitizer.dart' show Sanitizer, SanitizerLimits;
export 'src/sinks/console_sink.dart' show ConsoleSink;
export 'src/sinks/jsonl_file_sink.dart' show JsonlFileSink;
export 'src/sinks/jsonl_print_sink.dart' show JsonlPrintSink;
export 'src/sinks/log_sink.dart'
    show LogSink, MultiSink, MemorySink, LevelFilterSink;
export 'src/sinks/rate_limit_sink.dart' show RateLimitSink;
