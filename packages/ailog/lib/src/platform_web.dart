/// Web implementations of the platform hooks. No filesystem, no terminal.
library;

bool platformSupportsAnsi() => false;

String defaultLogDirectory() => '.';

Map<String, Object?> platformContext() => const {'os': 'web'};

void writeToStdout(String line) {
  // The browser console is the only sink available here.
  // ignore: avoid_print
  print(line);
}
