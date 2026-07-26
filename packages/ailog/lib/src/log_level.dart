/// Severity levels used across the package.
///
/// The numeric [severity] follows the same spacing as most logging
/// ecosystems (10/20/30/...), which leaves room for custom levels to be
/// mapped in between when bridging from another logger.
enum LogLevel {
  /// Fine-grained detail: every step, every value.
  ///
  /// The default level for `checkpoint()` and `interaction()`. A production
  /// `minimumLevel` normally excludes these from the file — but they are
  /// still recorded as breadcrumbs, so they reappear inside the causal chain
  /// of whatever fails next. Cheap to leave in the code for that reason.
  trace(10, 'trace'),

  /// Developer-facing detail worth keeping while working on something:
  /// cache hits, retry decisions, chosen code paths.
  debug(20, 'debug'),

  /// Something the program did that a reader would want to know about:
  /// "checkout started", "migration applied". The usual production floor.
  info(30, 'info'),

  /// Recovered from, but suspicious. A retry that succeeded, a fallback that
  /// was taken, a deprecated path still being hit.
  warn(40, 'warn'),

  /// A failure. Emitted by `logger.error()` and by a span that threw. Error
  /// and above carry a causal chain, and `JsonlFileSink` flushes immediately
  /// at this level so the line survives a process that dies next.
  error(50, 'error'),

  /// A failure the program did not survive. `runAppGuarded` and
  /// `runZonedGuarded` integrations record uncaught errors here.
  fatal(60, 'fatal');

  const LogLevel(this.severity, this.wireName);

  /// Numeric severity. Higher means more important.
  final int severity;

  /// Short, stable name written to the JSONL output.
  final String wireName;

  /// Whether this level should be emitted when [threshold] is configured.
  bool passes(LogLevel threshold) => severity >= threshold.severity;

  /// Parses a level from its [wireName]. Case insensitive.
  ///
  /// Returns `null` for unknown input so callers can decide on a fallback.
  static LogLevel? tryParse(String? name) {
    if (name == null) return null;
    final normalized = name.trim().toLowerCase();
    for (final level in LogLevel.values) {
      if (level.wireName == normalized) return level;
    }
    // Common aliases from other logging packages.
    switch (normalized) {
      case 'verbose':
      case 'finest':
      case 'finer':
        return LogLevel.trace;
      case 'fine':
        return LogLevel.debug;
      case 'config':
      case 'information':
        return LogLevel.info;
      case 'warning':
        return LogLevel.warn;
      case 'severe':
        return LogLevel.error;
      case 'shout':
      case 'critical':
        return LogLevel.fatal;
    }
    return null;
  }
}
