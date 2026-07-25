import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

/// Regression test for a real bug: `JsonlFileSink`'s default `flushInterval`
/// schedules a periodic [Timer], and only [close] — not [flush] — cancels
/// it. A script that called `flush()` and returned from `main()` hung
/// forever instead of exiting, because a live [Timer] keeps the isolate
/// alive. Confirmed by actually running the README's example verbatim.
///
/// This can only be observed from outside the isolate under test — a plain
/// unit test running in the same process as the test runner cannot tell
/// "did main() return" from "is something else keeping us alive" — so this
/// spawns a real `dart run` subprocess and asserts it exits promptly.
void main() {
  test(
    'a script that flushes and closes the sink exits promptly',
    () async {
      final result = await Process.run(
        Platform.resolvedExecutable, // the `dart` binary running this test
        ['run', 'test/regression/_process_exit_script.dart'],
        workingDirectory: Directory.current.path,
      ).timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw TimeoutException(
          'The script did not exit — JsonlFileSink.close() is not '
          'cancelling its periodic flush Timer, and the isolate is being '
          'kept alive.',
        ),
      );

      expect(result.exitCode, 0, reason: result.stderr.toString());
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
