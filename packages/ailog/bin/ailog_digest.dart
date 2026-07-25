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

import 'package:ailog/src/console_formatter.dart';
import 'package:ailog/src/digest.dart';
import 'package:ailog/src/digest_cli.dart';
import 'package:ailog/src/log_event.dart';
import 'package:ailog/src/platform.dart';

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

  if (options.format == DigestOutputFormat.pretty) {
    await _renderPretty(options);
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

/// `--format pretty`: not a digest — a replay. Re-renders each event the way
/// `ConsoleSink` would have shown it live, so a recovered file can be read
/// with human eyes before (or instead of) being summarized.
Future<void> _renderPretty(DigestCliOptions options) async {
  final toFile = options.outputPath != null;
  // ANSI colour helps a terminal and corrupts a file.
  final formatter = ConsoleFormatter(
    useColor: !toFile && platformSupportsAnsi(),
  );
  final out = StringBuffer();
  void emit(String line) => toFile ? out.writeln(line) : stdout.writeln(line);

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
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      Map<String, Object?>? json;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) json = decoded.cast<String, Object?>();
      } on FormatException {
        json = null;
      }

      if (json == null) {
        // Interleaved non-JSON (a stray print, a logcat banner). Pass it
        // through untouched rather than hiding it: what the file contains is
        // what the reader should see.
        emit(line);
        continue;
      }
      if (json['_hdr'] == true) continue;

      final event = LogEvent.fromJson(json);
      if (event == null) {
        emit(line);
        continue;
      }
      emit(formatter.format(event));
    }
  }

  if (!readAny) {
    exitCode = 66; // EX_NOINPUT
    return;
  }
  if (toFile) {
    await File(options.outputPath!).writeAsString(out.toString());
    stderr.writeln('ailog_digest: wrote ${options.outputPath}');
  }
}
