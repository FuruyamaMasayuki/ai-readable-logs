/// `dart run ailog:ailog_digest <file.jsonl> [options]`
///
/// Reduces one or more `ailog` JSONL files into a bounded summary sized for
/// pasting into an AI chat: total counts, error groups ranked by frequency,
/// and (for each group) the frames and causal chain of the most recent
/// occurrence.
library;

import 'dart:convert';
import 'dart:io';

import 'package:ailog/src/digest.dart';

Future<void> main(List<String> arguments) async {
  final options = _Options.parse(arguments);
  if (options == null) {
    _printUsage();
    exitCode = 64; // EX_USAGE
    return;
  }
  if (options.showHelp) {
    _printUsage();
    return;
  }

  if (options.paths.isEmpty) {
    stderr.writeln('ailog_digest: no input files given.\n');
    _printUsage();
    exitCode = 64;
    return;
  }

  final builder = DigestBuilder();
  var readAny = false;
  for (final path in options.paths) {
    final file = File(path);
    if (!file.existsSync()) {
      stderr.writeln('ailog_digest: file not found: $path');
      continue;
    }
    readAny = true;
    await for (final line in file
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      builder.addLine(line);
    }
  }

  if (!readAny) {
    exitCode = 66; // EX_NOINPUT
    return;
  }

  final digest = builder.build();
  final output = options.format == _Format.json
      ? const JsonEncoder.withIndent('  ')
          .convert(digest.toJson(maxGroups: options.maxGroups))
      : digest.toMarkdown(maxGroups: options.maxGroups);

  if (options.outputPath != null) {
    await File(options.outputPath!).writeAsString(output);
    stderr.writeln('ailog_digest: wrote ${options.outputPath}');
  } else {
    stdout.writeln(output);
  }
}

enum _Format { markdown, json }

class _Options {
  _Options({
    required this.paths,
    required this.format,
    required this.maxGroups,
    required this.outputPath,
    required this.showHelp,
  });

  final List<String> paths;
  final _Format format;
  final int maxGroups;
  final String? outputPath;
  final bool showHelp;

  static _Options? parse(List<String> arguments) {
    final paths = <String>[];
    var format = _Format.markdown;
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
            format = _Format.json;
          } else if (value == 'markdown' || value == 'md') {
            format = _Format.markdown;
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

    return _Options(
      paths: paths,
      format: format,
      maxGroups: maxGroups,
      outputPath: outputPath,
      showHelp: showHelp,
    );
  }
}

void _printUsage() {
  stdout.writeln('''
Usage: dart run ailog:ailog_digest <file.jsonl> [file2.jsonl ...] [options]

Reduces ailog JSONL output into a bounded digest for AI analysis.

Options:
  --format <markdown|json>   Output format (default: markdown)
  --max-groups <n>           Max error groups to include (default: 20)
  -o, --output <path>        Write to a file instead of stdout
  -h, --help                 Show this help
''');
}
