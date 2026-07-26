/// Serves the in-memory log over the Dart VM Service, so a development
/// machine can pull it off a running app with no file transfer step.
///
/// This closes the gap the rest of the retrieval options leave open. Reading
/// the file needs `adb pull` or Xcode; the share sheet needs a human to press
/// something; the `print`-based route rides a channel Android will silently
/// rate-limit under load. The VM Service is a socket the tooling already
/// opened — `flutter run` prints its URI on startup — and it is a *pull*, so
/// nothing is dropped when the app is busy.
///
/// It exists only where that socket does. Debug and profile builds serve the
/// VM Service; a release build does not, and [installDebugSync] additionally
/// refuses to register there, so the callback and the buffer it closes over
/// fold out of a release binary rather than sitting in it unreachable.
library;

import 'dart:convert';
import 'dart:developer' as developer;

import 'build_mode.dart';
import 'log_event.dart';
import 'platform.dart';
import 'sinks/log_sink.dart';

/// The name the CLI calls. A VM Service extension must start with `ext.`.
const String defaultDebugSyncExtension = 'ext.ailog.sync';

/// A registered debug-sync extension.
///
/// Returned by [installDebugSync] so a caller can tell whether registration
/// happened, and read back the values needed to talk to it.
class DebugSync {
  const DebugSync._({required this.extension, required this.registered});

  /// The service extension name the CLI should call.
  final String extension;

  /// Whether the extension was actually registered.
  ///
  /// `false` in a release build, on web, and if `dart:developer` refused
  /// (a name registered twice) — all of which are normal, and none of which
  /// is an error worth throwing over. Safe to show in a dev banner: it means
  /// `ailog_sync --vm-service` can actually reach this app, not merely that
  /// a call was made.
  ///
  /// Web is `false` deliberately. `registerExtension` returns without
  /// complaint under dart2js — verified by compiling and running it — but no
  /// VM Service exists in a browser, so the handler could never be invoked.
  final bool registered;
}

/// Serves [buffer]'s events over the VM Service for `ailog_sync` to pull.
///
/// Call it once at startup, after building the logger:
///
/// ```dart
/// final recent = MemorySink(capacity: 20000);
/// final logger = Logger.create(sink: MultiSink([fileSink, recent]));
/// installDebugSync(recent);
/// ```
///
/// Then, on your machine, with the VM Service URI `flutter run` printed:
///
/// ```sh
/// dart run ailog:ailog_sync --vm-service <uri> -o app.jsonl --watch
/// ```
///
/// ## Sizing the buffer
///
/// [MemorySink] is a rolling window, so anything that scrolls out before the
/// CLI asks for it is gone. That loss is *reported* rather than hidden — the
/// response carries how many events fell off, and `ailog_sync` writes the
/// count into its output — but reporting it is not the same as having it.
/// A capacity well above what one polling interval produces is the fix; the
/// events are already allocated, so retaining more of them is cheap.
///
/// ## What it does not do
///
/// It does not read the `JsonlFileSink`'s file. The file is the more
/// complete record, but reaching it would mean `dart:io` in a code path that
/// has to compile for web. What you get here is exactly what [buffer] holds.
///
/// Returns a [DebugSync] describing what happened — check
/// [DebugSync.registered] rather than assuming. Registering the same
/// [extension] name twice does not replace the first handler: `dart:developer`
/// throws, which is caught here and reported as `registered: false`. Pass a
/// distinct [extension] if you genuinely want two buffers served at once, and
/// tell the CLI which one to call.
DebugSync installDebugSync(
  MemorySink buffer, {
  String extension = defaultDebugSyncExtension,
}) {
  // Not `if (isReleaseBuild) return` inside the body — a const condition
  // guarding the *registration call* is what lets the AOT compiler drop the
  // closure below, and with it the reference that would otherwise pin the
  // buffer. Verified the same way as the sink-elimination pattern in
  // build_mode.dart.
  if (!isReleaseBuild && platformSupportsServiceExtensions) {
    try {
      developer.registerExtension(extension, (method, parameters) async {
        return developer.ServiceExtensionResponse.result(
          jsonEncode(debugSyncPayload(buffer, parameters['sinceSeq'])),
        );
      });
      return DebugSync._(extension: extension, registered: true);
    } catch (_) {
      // Registering a name twice throws. Not worth taking down the host
      // program for — this is a convenience, and the file sink is
      // unaffected either way.
    }
  }
  return DebugSync._(extension: extension, registered: false);
}

/// Builds the response payload: everything in [buffer] after [sinceSeqRaw].
///
/// Not exported from `package:ailog/ailog.dart` — it is the wire format
/// between [installDebugSync] and the `ailog_sync` CLI, and is split out from
/// the handler so both sides can be tested without a live VM Service.
///
/// [sinceSeqRaw] is a string because VM Service extension parameters always
/// are; anything unparseable is treated as `0`, meaning "send everything".
Map<String, Object?> debugSyncPayload(MemorySink buffer, String? sinceSeqRaw) {
  final sinceSeq = int.tryParse(sinceSeqRaw ?? '') ?? 0;
  final events = buffer.events;

  // `seq` is monotonic from 1 within a session, so "everything after the
  // cursor" is a filter rather than an index — correct even if the buffer
  // rolled over between calls, and correct across a restart, where the new
  // session's seq starts back at 1 and the session id changes with it.
  final fresh = <LogEvent>[];
  var lowestRetained = 0;
  for (final event in events) {
    if (lowestRetained == 0 || event.sequence < lowestRetained) {
      lowestRetained = event.sequence;
    }
    if (event.sequence > sinceSeq) fresh.add(event);
  }

  // What rolled out of the window between the caller's cursor and the oldest
  // event still held. Reported rather than swallowed: an incomplete log that
  // says so is usable, one that looks complete is misleading.
  final missed = lowestRetained > sinceSeq + 1 && sinceSeq > 0
      ? lowestRetained - sinceSeq - 1
      : 0;

  return {
    'schema': aiLogSchemaVersion,
    'session': events.isEmpty ? null : events.last.sessionId,
    'highestSeq': events.isEmpty ? sinceSeq : events.last.sequence,
    'missed': missed,
    'events': [for (final event in fresh) jsonEncode(event.toJson())],
  };
}
