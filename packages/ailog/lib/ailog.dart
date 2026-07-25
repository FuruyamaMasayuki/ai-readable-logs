/// AI解析に最適化されたJSONL構造化ロガー。
///
/// 依存ゼロのPure Dartパッケージ。トレース/セッション相関、因果チェーン、
/// エラーの自動要約・グルーピング（指紋化）、機密情報の自動マスキング、
/// AI向けダイジェスト生成を備える。
library ailog;

export 'src/causal_buffer.dart' show CausalBuffer;
export 'src/console_formatter.dart' show ConsoleFormatter;
export 'src/context.dart'
    show LogScope, currentScope, runWithScope, runWithScopeGuarded;
export 'src/ids.dart' show IdGenerator, fnv1a64, shortHash;
export 'src/log_event.dart'
    show LogEvent, ErrorInfo, aiLogSchemaVersion, schemaLegend;
export 'src/log_level.dart' show LogLevel;
export 'src/logger.dart';
export 'src/normalizer.dart'
    show StackFrame, parseStackTrace, normalizeMessage, errorFingerprint;
export 'src/redaction.dart'
    show
        Redactor,
        RedactionRule,
        builtInRedactionRules,
        defaultSensitiveKeyPattern;
export 'src/sanitizer.dart' show Sanitizer, SanitizerLimits;
export 'src/sinks/console_sink.dart' show ConsoleSink;
export 'src/sinks/jsonl_file_sink.dart' show JsonlFileSink;
export 'src/sinks/log_sink.dart'
    show LogSink, MultiSink, MemorySink, LevelFilterSink;
