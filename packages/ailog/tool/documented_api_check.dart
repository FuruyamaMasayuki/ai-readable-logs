// Every ailog API the READMEs document, referenced for real.
//
// Documentation drifts from code silently: a renamed method, a removed
// parameter, an example written from memory. Nothing catches it, because a
// README is not compiled. This file is — CI analyzes it — so a documented
// API that no longer exists becomes a build failure instead of a bug report.
//
// It caught `span.end()`, which the README's cheat sheet documented and the
// package never had (the real methods are `succeed()` and `fail()`).
//
// When you document a new API, add it here.
//
// ignore_for_file: unused_local_variable, avoid_print
import 'package:ailog/ailog.dart';

void main() {
  // Types
  const t = <Type>[
    ConsoleSink,
    Digest,
    DigestBuilder,
    JsonlFileSink,
    JsonlPrintSink,
    LevelFilterSink,
    LogFilter,
    LogLevel,
    LogScope,
    DebugSync,
    Logger,
    MemorySink,
    MultiSink,
    RedactionRule,
    Redactor,
    RateLimitSink,
    LogSink,
    LogSelection,
    Breadcrumb,
    CausalBuffer,
    ConsoleFormatter,
    ErrorGroup,
    MessageShape,
    NumericField,
    Sanitizer,
    SanitizerLimits,
    IdGenerator,
    SequenceCounter,
    LogEvent,
    ErrorInfo,
    CallSite,
    StackFrame,
    Span,
    BuildMode,
  ];

  // Top-level functions
  final fns = <Function>[
    buildDigest,
    digestFromJsonl,
    byBuildMode,
    capturePrints,
    runWithScope,
    runWithScopeGuarded,
    shortHash,
    fnv1a64Hex,
    captureCallSite,
    parseStackTrace,
    normalizeMessage,
    errorFingerprint,
    errorFingerprintFromFrames,
    schemaLegend,
    sensitiveKeyWords,
  ];

  // Compile-time constants — `const` here is part of the assertion: these
  // must stay usable in a const context.
  const compileTimeConstants = <Object>[
    aiLogSchemaVersion,
    isDebugBuild,
    isProfileBuild,
    isReleaseBuild,
    currentBuildMode,
  ];

  // Top-level finals (a RegExp and a List cannot be const).
  final topLevelFinals = <Object>[
    defaultSensitiveKeyPattern,
    builtInRedactionRules,
  ];

  // The debug-sync surface the READMEs document.
  final syncBuffer = MemorySink(capacity: 20000);
  final DebugSync sync =
      installDebugSync(syncBuffer, extension: defaultDebugSyncExtension);
  final bool syncRegistered = sync.registered;
  final String syncExtension = sync.extension;

  // Logger surface used in docs
  final logger = Logger.create(sink: MemorySink());
  final testing = Logger.forTesting();
  final off = Logger.disabled();
  logger.child('db');
  logger.trace('x');
  logger.debug('x');
  logger.info('x');
  logger.warn('x');
  logger.errorMessage('x');
  logger.error(StateError('e'), null);
  logger.fatal(StateError('e'), null);
  logger.log(LogLevel.info, 'x');
  logger.checkpoint();
  logger.interaction('checkout_pressed', context: {'items': 3});
  logger.isEnabled(LogLevel.info);
  logger.isRecorded(LogLevel.info);
  logger.startTrace();
  final span = logger.startSpan('s');
  span.scope;
  span.elapsedMs;
  span.succeed();
  logger.startSpan('s2').fail(StateError('e'), StackTrace.current);
  logger.spanSync('s', (s) => 1);
  logger.span('s', (s) async => 1);
  logger.minimumLevel;
  logger.sessionId;
  logger.flush();
  logger.close();
  Logger.checkpointsResolveCallSites();

  // Sinks / export surface
  final mem = MemorySink();
  mem.toJsonl();
  mem.toMarkdown();
  mem.export(LogFilter.forAi);
  LogFilter.none;
  LogFilter.forAi;
  final sel = mem.export();
  sel.toJsonl();
  sel.toMarkdown();
  sel.toReport();
  sel.events;
  sel.inputCount;
  sel.droppedBy;
  sel.droppedCount;
  sel.digest;
  ConsoleSink.usingPrint();
  ConsoleSink(write: print);
  JsonlPrintSink(write: print);
  print('all README identifiers resolve');
}
