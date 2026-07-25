import 'dart:io';

/// Whether the terminal understands ANSI colour codes.
bool platformSupportsAnsi() {
  try {
    if (Platform.environment['NO_COLOR'] != null) return false;
    if (Platform.environment['TERM'] == 'dumb') return false;
    return stdout.hasTerminal && stdout.supportsAnsiEscapes;
  } catch (_) {
    return false;
  }
}

/// Default directory for log files, overridable via `AILOG_DIR`.
String defaultLogDirectory() {
  final override = Platform.environment['AILOG_DIR'];
  if (override != null && override.isNotEmpty) return override;
  return '${Directory.current.path}${Platform.pathSeparator}.ailog';
}

/// Environment facts worth recording once per session.
///
/// "Reproduces only on Linux with Dart 3.9" is a conclusion a model can only
/// reach if the log says which platform produced it.
Map<String, Object?> platformContext() {
  try {
    return {
      'os': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'dart': Platform.version.split(' ').first,
      'pid': pid,
      'numberOfProcessors': Platform.numberOfProcessors,
      'locale': Platform.localeName,
    };
  } catch (_) {
    return const {};
  }
}

/// Writes directly to stdout without the line buffering `print` applies.
void writeToStdout(String line) {
  try {
    stdout.writeln(line);
  } catch (_) {
    // stdout can be closed (daemonised process); ignore.
  }
}
