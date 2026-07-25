// Not a test file (no `_test.dart` suffix, so `dart test` skips it). Run as
// a subprocess by process_exit_test.dart, which is the only thing that can
// actually observe "does the process exit" — a unit test running inside the
// same isolate as the test runner cannot.
import 'dart:io';

import 'package:ailog/ailog.dart';

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('ailog_exit_');
  // Default flushInterval (2s): this is the case that used to hang, because
  // flush() does not cancel the periodic Timer.
  final logger =
      Logger.create(sink: JsonlFileSink(path: '${dir.path}/app.jsonl'));
  logger.info('hello');
  await logger.flush();
  await logger.close();
  await dir.delete(recursive: true);
  // Reaching here and returning from main() is the assertion: if close()
  // stopped cancelling the timer, this process would hang past the parent
  // test's timeout instead.
}
