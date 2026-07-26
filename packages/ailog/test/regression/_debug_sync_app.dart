// The "app" half of test/regression/debug_sync_test.dart.
//
// Run under `dart run --observe`, it registers the sync extension and then
// logs steadily, so the CLI has a live VM Service to pull from. Kept in a
// separate file because the test spawns it as a real process — an in-process
// fake would prove the payload shape and nothing about the transport, which
// is the part that actually breaks.
//
// ignore_for_file: avoid_print
library;

import 'dart:async';
import 'dart:io';

import 'package:ailog/ailog.dart';

Future<void> main(List<String> args) async {
  final buffer = MemorySink(capacity: int.parse(args.first));
  final logger = Logger.create(sink: buffer, enabled: true);

  final sync = installDebugSync(buffer);
  print('AILOG_SYNC_READY registered=${sync.registered}');

  var n = 0;
  final done = Completer<void>();
  Timer.periodic(const Duration(milliseconds: 50), (timer) {
    logger.info('event $n', context: {'i': n});
    n++;
    if (n >= 40) {
      timer.cancel();
      print('AILOG_SYNC_DONE emitted=$n');
      done.complete();
    }
  });

  await done.future;
  // A grace period so a --watch run gets a poll or two after the last event,
  // then exit — which is also what makes the CLI's clean-disconnect path the
  // thing under test rather than a timeout.
  await Future<void>.delayed(const Duration(seconds: 3));
  exit(0);
}
