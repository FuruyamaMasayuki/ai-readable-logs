/// Argument parsing for the `ailog_digest` CLI, split out from `bin/` so it
/// can be unit tested directly instead of only through process-spawning
/// integration tests.
library;

/// What `ailog_digest --format` can produce.
enum DigestOutputFormat {
  /// A bounded digest as Markdown — the default, and what you paste into a
  /// chat. Written for a reader, model or human, rather than a parser.
  markdown,

  /// The same digest as JSON, for a program to consume.
  json,

  /// Not a digest at all: re-render every event through `ConsoleFormatter`,
  /// the same way `ConsoleSink` shows it during development.
  ///
  /// Exists for the person holding a recovered `app.jsonl` — off a device,
  /// out of a bug report — who wants to *look* at it before (or instead of)
  /// summarizing it. The pieces always existed (`LogEvent.fromJson` +
  /// `ConsoleFormatter.format`); this flag is the missing glue.
  pretty,
}

/// Parsed command-line options for `ailog_digest`.
class DigestCliOptions {
  /// Builds an option set directly. [parse] is the usual entry point.
  DigestCliOptions({
    required this.paths,
    required this.format,
    required this.maxGroups,
    required this.outputPath,
    required this.showHelp,
  });

  /// Input `.jsonl` files, in the order given.
  ///
  /// Several are folded into one digest, which is how a rotated set
  /// (`app.jsonl`, `app.1.jsonl`, …) is read as a single history. Order does
  /// not affect the result.
  final List<String> paths;

  /// What to emit — `--format`.
  final DigestOutputFormat format;

  /// How many error groups the output may contain — `--max-groups`.
  /// Groups are sorted by distinct failures, so the cut drops the rarest.
  final int maxGroups;

  /// Where to write — `-o`/`--output`. `null` means stdout.
  ///
  /// Worth passing for `--format pretty`, whose colour codes are only emitted
  /// for a terminal and would be noise in a redirected file.
  final String? outputPath;

  /// Whether `-h`/`--help` was given, in which case the caller should print
  /// [digestCliUsage] and exit successfully.
  final bool showHelp;

  /// Parses [arguments]. Returns `null` when the arguments are malformed
  /// (unknown flag, missing value, invalid number) so the caller can print
  /// usage and exit with a non-zero code.
  static DigestCliOptions? parse(List<String> arguments) {
    final paths = <String>[];
    var format = DigestOutputFormat.markdown;
    var maxGroups = 20;
    String? outputPath;
    var showHelp = false;

    var i = 0;
    while (i < arguments.length) {
      final arg = arguments[i];
      switch (arg) {
        case '-h':
        case '--help':
          showHelp = true;
          i++;
        case '--format':
          if (i + 1 >= arguments.length) return null;
          final value = arguments[i + 1];
          if (value == 'json') {
            format = DigestOutputFormat.json;
          } else if (value == 'markdown' || value == 'md') {
            format = DigestOutputFormat.markdown;
          } else if (value == 'pretty') {
            format = DigestOutputFormat.pretty;
          } else {
            return null;
          }
          i += 2;
        case '--max-groups':
          if (i + 1 >= arguments.length) return null;
          final parsed = int.tryParse(arguments[i + 1]);
          if (parsed == null || parsed < 1) return null;
          maxGroups = parsed;
          i += 2;
        case '-o':
        case '--output':
          if (i + 1 >= arguments.length) return null;
          outputPath = arguments[i + 1];
          i += 2;
        default:
          if (arg.startsWith('-')) return null;
          paths.add(arg);
          i++;
      }
    }

    return DigestCliOptions(
      paths: paths,
      format: format,
      maxGroups: maxGroups,
      outputPath: outputPath,
      showHelp: showHelp,
    );
  }
}

/// The `--help` text, printed verbatim when [DigestCliOptions.showHelp] is
/// set or when [DigestCliOptions.parse] returns `null`.
const String digestCliUsage = '''
Usage: dart run ailog:ailog_digest <file.jsonl> [file2.jsonl ...] [options]

Reduces ailog JSONL output into a bounded digest for AI analysis.

Options:
  --format <markdown|json|pretty>
                             markdown/json: a bounded digest (default: markdown).
                             pretty: no digest — re-render every event the way
                             the console shows it, for reading a recovered
                             .jsonl file with human eyes.
  --max-groups <n>           Max error groups to include (default: 20)
  -o, --output <path>        Write to a file instead of stdout
  -h, --help                 Show this help
''';
