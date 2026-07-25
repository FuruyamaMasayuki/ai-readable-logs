/// One-tap sharing of ailog output through log_vault's share sheet.
///
/// ailog produces the artifacts (JSONL + digest); log_vault owns the export
/// path users already understand (zip → platform share sheet). This class is
/// the seam between them, and deliberately nothing more: it does not log,
/// does not own a sink, and works whether or not `LogVault.init` was ever
/// called.
library;

import 'dart:io';

import 'package:ailog/ailog.dart';
import 'package:flutter/widgets.dart';
import 'package:log_vault/log_vault.dart' as vault;
import 'package:share_plus/share_plus.dart' show ShareResult;

import 'digest_writer.dart';

/// Zips the ailog directory — `.jsonl` files, rotations, and a freshly
/// generated `digest.md` — and hands it to the platform share sheet.
///
/// ```dart
/// final share = AilogVaultShare(
///   logDirectory: Directory(logDir),
///   appName: 'my_app',
///   flush: logger.flush,
/// );
///
/// // In a "send logs" button:
/// await share.share(context, subject: 'my_app logs');
/// ```
///
/// The digest is regenerated on every dump so it always describes the files
/// beside it. It is the first thing whoever receives the zip should read —
/// and often the only thing an AI needs.
class AilogVaultShare {
  AilogVaultShare({
    required this.logDirectory,
    required this.appName,
    this.flush,
    this.digestFileName = 'digest.md',
    this.maxGroups = 20,
  }) : _dumper = vault.LogDumper(
          directory: logDirectory,
          appName: appName,
          // The digest is regenerated in writeDigest() (which also awaits
          // [flush]) before every dump, so the dumper itself needs no flush
          // hook — passing it here too would await it twice per dump.
          flush: null,
          extraPatterns: [
            jsonlFilePattern,
            RegExp(r'\.md$'),
          ],
        );

  /// Where [JsonlFileSink] writes. Only this directory's top level is read.
  final Directory logDirectory;

  /// Used in the zip's file name and metadata.
  final String appName;

  /// Awaited before snapshotting, typically `logger.flush`. Without it, the
  /// most recent events — the ones the share is probably about — may still
  /// be sitting in the sink's buffer.
  final Future<void> Function()? flush;

  /// Name of the generated digest inside [logDirectory].
  final String digestFileName;

  /// Error groups included in the digest.
  final int maxGroups;

  final vault.LogDumper _dumper;

  /// Builds the digest from every `.jsonl` file currently in
  /// [logDirectory] and writes it beside them.
  ///
  /// Returns the digest, so callers that only want the summary (a support
  /// form's preview pane, a quick triage) can use it without zipping.
  Future<Digest> writeDigest() async {
    await flush?.call();
    return writeDigestForDirectory(
      logDirectory,
      digestFileName: digestFileName,
      maxGroups: maxGroups,
    );
  }

  /// Regenerates the digest, then zips it together with the JSONL files.
  ///
  /// Returns the zip; the caller owns uploading or attaching it. Call
  /// [dispose] when done with it.
  Future<File> dump({Map<String, Object?> metadata = const {}}) async {
    final digest = await writeDigest();
    return _dumper.dumpLogs(metadata: {
      'generator': 'ailog',
      'schema': aiLogSchemaVersion,
      'events': digest.totalEvents,
      'errorGroups': digest.errorGroups.length,
      ...metadata,
    });
  }

  /// [dump], then the platform share sheet.
  Future<ShareResult> share(
    BuildContext context, {
    String? subject,
    Map<String, Object?> metadata = const {},
    Rect? sharePositionOrigin,
  }) async {
    // The digest must exist before ShareLogDumper snapshots the directory,
    // and ShareLogDumper drives the same LogDumper instance, so its internal
    // queue keeps dump ordering sane even if share is double-tapped.
    await writeDigest();
    return vault.ShareLogDumper(_dumper).share(
      context,
      subject: subject ?? '$appName logs',
      metadata: {
        'generator': 'ailog',
        'schema': aiLogSchemaVersion,
        ...metadata,
      },
      sharePositionOrigin: sharePositionOrigin,
    );
  }

  /// Deletes the temp zip produced by the previous [dump]/[share], if any.
  Future<void> dispose() => _dumper.disposeLastDump();
}
