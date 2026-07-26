/// Web implementations of the platform hooks. No filesystem, no terminal.
library;

/// Always `false` — a browser console renders ANSI escapes as literal text.
bool platformSupportsAnsi() => false;

/// A placeholder. There is no filesystem on web, so nothing uses this except
/// code shared with the VM implementation.
String defaultLogDirectory() => '.';

/// The platform fields written into each file's `_hdr` line. Only `os` is
/// knowable here without reaching into browser APIs.
Map<String, Object?> platformContext() => const {'os': 'web'};

/// Writes one line to the browser console, there being no stdout.
void writeToStdout(String line) {
  // The browser console is the only sink available here.
  // ignore: avoid_print
  print(line);
}
