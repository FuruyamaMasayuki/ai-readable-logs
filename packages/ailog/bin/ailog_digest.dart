/// `dart run ailog:ailog_digest <file.jsonl> [options]`
///
/// Reduces one or more `ailog` JSONL files into a bounded summary sized for
/// pasting into an AI chat: total counts, error groups ranked by frequency,
/// and (for each group) the frames and causal chain of the most recent
/// occurrence.
///
/// Argument parsing lives in `lib/src/digest_cli.dart` so it is unit
/// testable; this file is just the I/O glue.
library;

import 'dart:convert';
import 'dart:io';

import 'package:ailog/src/digest.dart';
import 'package:ailog/src/digest_cli.dart';

Future<void> main(List<String> arguments) async {
  final options = DigestCliOptions.parse(arguments);
  if (options == null) {
    stdout.writeln(digestCliUsage);
    exitCode = 64; // EX_USAGE
    return;
  }
  if (options.showHelp) {
    stdout.writeln(digestCliUsage);
    return;
  }

  if (options.paths.isEmpty) {
    stderr.writeln('ailog_digest: no input files given.\n');
    stdout.writeln(digestCliUsage);
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
  final output = options.format == DigestOutputFormat.json
      ? const JsonEncoder.withIndent(
          '  ',
        ).convert(digest.toJson(maxGroups: options.maxGroups))
      : digest.toMarkdown(maxGroups: options.maxGroups);

  if (options.outputPath != null) {
    await File(options.outputPath!).writeAsString(output);
    stderr.writeln('ailog_digest: wrote ${options.outputPath}');
  } else {
    stdout.writeln(output);
  }
}
