/// Argument parsing and line extraction for the `ailog_sync` CLI, split out
/// from `bin/` so they can be unit tested directly instead of only through
/// process-spawning integration tests.
library;

import 'dart:convert';

/// Where `ailog_sync` reads events from.
enum SyncSource {
  /// Pull them out of a running app over the Dart VM Service.
  ///
  /// The app must have called `installDebugSync`. This is a pull over a real
  /// socket, so nothing is dropped when the app is busy, and attaching late
  /// still gets everything the app's buffer is still holding.
  vmService,

  /// Read stdin, keeping the lines that are `ailog` JSONL.
  ///
  /// For `flutter run | dart run ailog:ailog_sync`. Needs no extra API call
  /// in the app — only a `JsonlPrintSink` in the sink list — but it rides the
  /// same log channel Android rate-limits, so a busy app can lose lines.
  stdin,
}

/// Parsed command-line options for `ailog_sync`.
class SyncCliOptions {
  /// Builds an option set directly. [parse] is the usual entry point.
  SyncCliOptions({
    required this.source,
    required this.outputPath,
    required this.vmServiceUri,
    required this.interval,
    required this.follow,
    required this.digest,
    required this.showHelp,
  });

  /// Which transport to read from.
  final SyncSource source;

  /// The local `.jsonl` file to append to — `-o`/`--output`.
  ///
  /// Appended to rather than truncated, so re-attaching to a restarted app
  /// keeps the earlier session in the same file. Sessions stay separable
  /// because every event carries `ses`.
  final String outputPath;

  /// The VM Service URI printed by `flutter run` — `--vm-service`.
  ///
  /// `null` in [SyncSource.stdin] mode.
  final Uri? vmServiceUri;

  /// How long to wait between polls — `--interval`, in seconds.
  ///
  /// Only meaningful with [follow]. The cost of a poll that finds nothing is
  /// one small round trip, so a short interval is cheap; the app's buffer
  /// capacity is what actually has to cover the gap.
  final Duration interval;

  /// Keep polling until interrupted — `--watch`.
  ///
  /// Without it, one poll runs and the process exits, which is the form to
  /// use from a script or a build step.
  final bool follow;

  /// Print a digest to stdout after syncing — `--digest`.
  final bool digest;

  /// Whether `-h`/`--help` was given.
  final bool showHelp;

  /// Parses [arguments]. Returns `null` when they are malformed (unknown
  /// flag, missing value, unparseable URI or number) so the caller can print
  /// usage and exit non-zero.
  ///
  /// The source is inferred: `--vm-service` selects [SyncSource.vmService],
  /// its absence selects [SyncSource.stdin]. There is no flag to set it
  /// directly, because a mode that contradicts the arguments given would only
  /// ever be a mistake.
  static SyncCliOptions? parse(List<String> arguments) {
    String? outputPath;
    Uri? vmServiceUri;
    var interval = const Duration(seconds: 2);
    var follow = false;
    var digest = false;
    var showHelp = false;

    var i = 0;
    while (i < arguments.length) {
      final arg = arguments[i];
      switch (arg) {
        case '-h':
        case '--help':
          showHelp = true;
          i++;
        case '--watch':
        case '-w':
          follow = true;
          i++;
        case '--digest':
          digest = true;
          i++;
        case '--vm-service':
          if (i + 1 >= arguments.length) return null;
          final parsed = Uri.tryParse(arguments[i + 1]);
          if (parsed == null || !parsed.hasAuthority) return null;
          vmServiceUri = parsed;
          i += 2;
        case '--interval':
          if (i + 1 >= arguments.length) return null;
          final seconds = num.tryParse(arguments[i + 1]);
          if (seconds == null || seconds <= 0) return null;
          interval = Duration(milliseconds: (seconds * 1000).round());
          i += 2;
        case '-o':
        case '--output':
          if (i + 1 >= arguments.length) return null;
          outputPath = arguments[i + 1];
          i += 2;
        default:
          return null;
      }
    }

    return SyncCliOptions(
      source: vmServiceUri == null ? SyncSource.stdin : SyncSource.vmService,
      outputPath: outputPath ?? '.ailog/synced.jsonl',
      vmServiceUri: vmServiceUri,
      interval: interval,
      follow: follow,
      digest: digest,
      showHelp: showHelp,
    );
  }
}

/// Pulls an `ailog` JSONL object out of one line of piped run output, or
/// returns `null` if the line is not one.
///
/// The line is rarely clean. On Android the app's output is routed through
/// logcat, which prepends `I/flutter ( 1234): `, and `flutter run` adds its
/// own prefixes — so the JSON does not start at column 0 and cannot be found
/// by anchoring. This scans for the first `{`, then accepts the remainder
/// only if it parses as a JSON object that looks like one of ours.
///
/// "Looks like ours" is checked rather than assumed, because a log file is
/// full of other people's JSON: a pretty-printed API response, a stack trace
/// containing a map literal. An accepted line has either `_hdr` (the schema
/// legend) or both `ts` and `lvl`, which is the minimum `LogEvent.fromJson`
/// needs to produce anything.
String? extractJsonlLine(String line) {
  final start = line.indexOf('{');
  if (start < 0) return null;
  final candidate = line.substring(start).trimRight();

  final Object? decoded;
  try {
    decoded = jsonDecode(candidate);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  if (decoded['_hdr'] == true) return candidate;
  if (decoded['ts'] is String && decoded['lvl'] is String) return candidate;
  return null;
}

/// The `--help` text, printed verbatim when [SyncCliOptions.showHelp] is set
/// or when [SyncCliOptions.parse] returns `null`.
const String syncCliUsage = '''
Usage: dart run ailog:ailog_sync [options]

Pulls an ailog JSONL log off a running debug build onto this machine, so
`ailog_digest` has a file to read without adb pull or Xcode.

Two sources. Both need a debug or profile build — a release build serves no
VM Service, and installDebugSync does not register there.

  1. VM Service (recommended). The app calls installDebugSync(buffer) once;
     this connects to the URI `flutter run` prints and pulls the events.
     A pull over a socket, so a busy app drops nothing.

       dart run ailog:ailog_sync --vm-service http://127.0.0.1:PORT/TOKEN=/ \\
         -o app.jsonl --watch

  2. stdin. The app adds JsonlPrintSink to its sinks; this keeps the JSONL
     lines out of the run output. No extra call in the app, but it rides the
     log channel Android rate-limits, so lines can be lost under load.

       flutter run | dart run ailog:ailog_sync -o app.jsonl

Options:
  --vm-service <uri>   VM Service URI from `flutter run`. Selects source 1;
                       omitting it selects source 2.
  -o, --output <path>  File to append to (default: .ailog/synced.jsonl)
  -w, --watch          Keep syncing until interrupted, instead of once
  --interval <sec>     Seconds between polls with --watch (default: 2)
  --digest             Print a digest to stdout when syncing finishes
  -h, --help           Show this help
''';
