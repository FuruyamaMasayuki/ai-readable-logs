/// Builds a digest from the `.jsonl` files in a directory and writes it
/// beside them.
///
/// Pure Dart on purpose: this is the half of the share flow that carries the
/// actual logic (which files, what order, what output), kept free of Flutter
/// and plugin imports so it is testable anywhere `dart test` runs.
library;

import 'dart:convert';
import 'dart:io';

import 'package:ailog/ailog.dart';
import 'package:path/path.dart' as p;

/// Matches `app.jsonl` and its rotations `app.jsonl.1` … `app.jsonl.N`.
final RegExp jsonlFilePattern = RegExp(r'\.jsonl(\.\d+)?$');

/// Reads every `.jsonl` file at the top level of [directory] (oldest
/// rotation first), builds a [Digest], and writes it as Markdown to
/// [digestFileName] in the same directory.
///
/// Returns the digest. A missing or empty directory produces an empty
/// digest and still writes the file, so the share flow never has to
/// special-case "no logs yet".
Future<Digest> writeDigestForDirectory(
  Directory directory, {
  String digestFileName = 'digest.md',
  int maxGroups = 20,
}) async {
  final builder = DigestBuilder();
  if (await directory.exists()) {
    final files = <File>[];
    await for (final entity in directory.list()) {
      if (entity is File && jsonlFilePattern.hasMatch(p.basename(entity.path))) {
        files.add(entity);
      }
    }
    // Oldest rotation first, so the digest's time range and first/last-seen
    // fields read in chronological order.
    files.sort((a, b) => _rotationRank(b.path) - _rotationRank(a.path));
    for (final file in files) {
      // Streamed line-by-line rather than readAsString: rotations are
      // allowed to be large, and the builder only ever needs one line.
      await for (final line in file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        builder.addLine(line);
      }
    }
  }
  final digest = builder.build();
  final digestFile = File(p.join(directory.path, digestFileName));
  await digestFile.parent.create(recursive: true);
  await digestFile.writeAsString(digest.toMarkdown(maxGroups: maxGroups));
  return digest;
}

/// `app.jsonl` → 0, `app.jsonl.3` → 3. Higher = older.
int _rotationRank(String path) {
  final match = RegExp(r'\.jsonl\.(\d+)$').firstMatch(path);
  return match == null ? 0 : int.parse(match.group(1)!);
}
