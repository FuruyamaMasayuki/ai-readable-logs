/// `dart run ailog:ailog_sync [options]`
///
/// Pulls the log off a running debug build onto this machine, so
/// `ailog_digest` has a file to read without `adb pull` or Xcode.
///
/// Argument parsing lives in `lib/src/sync_cli.dart` so it is unit testable;
/// this file is the I/O glue.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ailog/src/debug_sync.dart';
import 'package:ailog/src/digest.dart';
import 'package:ailog/src/sync_cli.dart';
import 'package:ailog/src/vm_service_client.dart';

Future<void> main(List<String> arguments) async {
  final options = SyncCliOptions.parse(arguments);
  if (options == null) {
    stdout.writeln(syncCliUsage);
    exitCode = 64; // EX_USAGE
    return;
  }
  if (options.showHelp) {
    stdout.writeln(syncCliUsage);
    return;
  }

  final output = File(options.outputPath);
  await output.parent.create(recursive: true);
  // Append rather than truncate: re-attaching to a restarted app should add
  // to the history, not replace it. Every event carries `ses`, so the digest
  // can still tell the runs apart.
  final sink = output.openWrite(mode: FileMode.append);

  var written = 0;
  try {
    written = switch (options.source) {
      SyncSource.vmService => await _syncFromVmService(options, sink),
      SyncSource.stdin => await _syncFromStdin(options, sink),
    };
  } finally {
    await sink.flush();
    await sink.close();
  }

  stderr.writeln('ailog_sync: $written events -> ${options.outputPath}');

  if (options.digest && written > 0) {
    final builder = DigestBuilder();
    await for (final line in output
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      builder.addLine(line);
    }
    stdout.writeln(builder.build().toMarkdown());
  }
}

/// Polls the app's `ext.ailog.sync` extension, appending each batch.
Future<int> _syncFromVmService(SyncCliOptions options, IOSink sink) async {
  final VmServiceClient client;
  try {
    client = await VmServiceClient.connect(options.vmServiceUri!);
  } on SocketException catch (error) {
    stderr.writeln('ailog_sync: cannot reach the VM Service at '
        '${options.vmServiceUri} — is the app running?\n  $error');
    exitCode = 69; // EX_UNAVAILABLE
    return 0;
  }

  final isolateId = await client.mainIsolateId();
  if (isolateId == null) {
    stderr.writeln('ailog_sync: the VM reports no isolates.');
    exitCode = 69;
    await client.close();
    return 0;
  }

  // `seq` is monotonic from 1 per session, so it doubles as the cursor: ask
  // for everything above what we already have and the app sends exactly the
  // new events, no diffing on either side.
  var cursor = 0;
  var written = 0;
  var interrupted = false;

  // Ctrl-C has to leave a valid file behind — the whole point is that the
  // log survives the debugging session.
  final signals = ProcessSignal.sigint.watch().listen((_) {
    interrupted = true;
  });

  try {
    do {
      final Map<String, Object?> payload;
      try {
        payload = await client.call(
          defaultDebugSyncExtension,
          {'isolateId': isolateId, 'sinceSeq': '$cursor'},
        );
      } on VmServiceException catch (error) {
        // The app going away is how a debugging session normally ends —
        // you stop `flutter run`, or hot-restart. Everything synced so far
        // is on disk and valid, so this is a clean exit, not a failure.
        if (client.isClosed) {
          stderr.writeln('ailog_sync: the app disconnected.');
          break;
        }
        stderr.writeln('ailog_sync: $error');
        if (written == 0) {
          stderr.writeln('  The app has not registered the extension. Call '
              'installDebugSync(buffer) at startup, and make sure this is a '
              'debug or profile build.');
        }
        exitCode = 69;
        break;
      }

      final missed = (payload['missed'] as num?)?.toInt() ?? 0;
      if (missed > 0) {
        // Said out loud rather than swallowed. A gap the reader knows about
        // is a caveat; one they don't is a wrong conclusion.
        stderr.writeln('ailog_sync: $missed events rolled out of the app\'s '
            'buffer before this poll. Raise MemorySink(capacity:) or lower '
            '--interval.');
      }

      final events = payload['events'];
      if (events is List) {
        for (final line in events) {
          sink.writeln(line);
          written++;
        }
      }
      final highest = (payload['highestSeq'] as num?)?.toInt();
      if (highest != null && highest > cursor) cursor = highest;

      if (!options.follow || interrupted) break;
      // Flushed every round, so Ctrl-C — or the app dying mid-poll — leaves
      // a complete file behind rather than a truncated one.
      await sink.flush();
      await Future<void>.delayed(options.interval);
      // Deliberately *not* `while (!client.isClosed)`: the app usually exits
      // during that delay, and letting the loop condition catch it would end
      // the run silently. Going round again instead makes the next `call`
      // throw, which routes every disconnect through the one handler that
      // says so.
    } while (!interrupted);
  } finally {
    await signals.cancel();
    await client.close();
  }

  return written;
}

/// Keeps the JSONL lines out of piped `flutter run` output.
Future<int> _syncFromStdin(SyncCliOptions options, IOSink sink) async {
  var written = 0;
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final extracted = extractJsonlLine(line);
    if (extracted == null) {
      // Not ours — echo it, so piping through this stays usable as a
      // replacement for running `flutter run` on its own.
      stdout.writeln(line);
      continue;
    }
    sink.writeln(extracted);
    written++;
  }
  return written;
}
