/// Severity levels used across the package.
///
/// The numeric [severity] follows the same spacing as most logging
/// ecosystems (10/20/30/...), which leaves room for custom levels to be
/// mapped in between when bridging from another logger.
enum LogLevel {
  trace(10, 'trace'),
  debug(20, 'debug'),
  info(30, 'info'),
  warn(40, 'warn'),
  error(50, 'error'),
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
