/// Turns raw stack traces and messages into stable, low-noise shapes so that
/// two occurrences of "the same" problem hash to the same fingerprint.
library;

import 'ids.dart';

/// A single parsed stack frame, reduced to what an analyst actually reads.
class StackFrame {
  /// Creates a frame from already-split parts. [parseStackTrace] produces
  /// these; there is rarely a reason to build one by hand.
  const StackFrame({
    required this.location,
    required this.member,
    required this.isApp,
  });

  /// e.g. `package:my_app/checkout/cart.dart:42`
  final String location;

  /// e.g. `Cart.checkout`
  final String member;

  /// False for SDK / async-machinery / third-party frames.
  final bool isApp;

  /// Compact single-line rendering used in the JSONL output.
  String render() => member.isEmpty ? location : '$location $member';

  /// [location] with any trailing `:<line>` removed.
  ///
  /// Fingerprints deliberately ignore line numbers so an edit above the
  /// failing line doesn't split an error group. Deriving that from an
  /// already-parsed frame avoids parsing the same stack trace a second time —
  /// measured at over half the cost of logging an error.
  String get locationWithoutLineNumber {
    final lastColon = location.lastIndexOf(':');
    if (lastColon <= 0) return location;
    final suffix = location.substring(lastColon + 1);
    if (suffix.isEmpty || int.tryParse(suffix) == null) return location;
    return location.substring(0, lastColon);
  }

  @override
  String toString() => render();
}

/// Frames that carry no information about *where* a bug is.
///
/// `package:ailog` is in here for the same reason the others are: the logger
/// is never the bug. A blind diagnosis run on a digest whose top frames read
/// `runWithScope`, `_rootRun`, `_CustomZone.run` reported that the stack
/// "does not identify the leasing code" — the five-frame budget had been
/// spent entirely on this package's own zone plumbing. Demoting these frames
/// keeps them available as filler while letting real application frames take
/// the slots that matter, and keeps them out of the fingerprint, where they
/// would make unrelated bugs logged through the same helper look alike.
final RegExp _noiseFrame = RegExp(
  r'^(dart:async|dart:async-patch|dart:isolate|dart:isolate-patch|'
  r'package:stack_trace|package:test_api|package:test_core|package:matcher|'
  r'package:ailog/|package:ailog_flutter/)',
);

final RegExp _dartFrame = RegExp(
  // #0      Foo.bar (package:app/x.dart:10:5)
  r'^#\d+\s+(.+?)\s+\((.+?)\)$',
);

final RegExp _jsFrame = RegExp(
  //     at Foo.bar (http://host/main.dart.js:1:2)
  r'^\s*at\s+(.+?)\s+\((.+?)\)\s*$',
);

/// Strips the `:column` suffix and any absolute path prefix from a location.
String _normalizeLocation(String raw, {required bool keepLineNumbers}) {
  var location = raw.trim();

  // Drop a trailing `:line:column` -> `:line`, or both when line numbers are
  // not wanted (fingerprinting keeps them off so that unrelated edits above
  // the failing line do not split an error group).
  final parts = location.split(':');
  if (parts.length >= 3) {
    final maybeColumn = int.tryParse(parts.last);
    final maybeLine = int.tryParse(parts[parts.length - 2]);
    if (maybeColumn != null && maybeLine != null) {
      location = parts.sublist(0, parts.length - 2).join(':');
      if (keepLineNumbers) location = '$location:$maybeLine';
    } else if (maybeColumn != null) {
      location = parts.sublist(0, parts.length - 1).join(':');
      if (keepLineNumbers) location = '$location:$maybeColumn';
    }
  }

  // `file:///build/xyz/lib/src/a.dart` -> `lib/src/a.dart`, so that builds from
  // different machines or CI paths still group together.
  if (location.startsWith('file://') || location.startsWith('/')) {
    final segments = location.split('/');
    final libIndex = segments.lastIndexOf('lib');
    if (libIndex != -1) {
      location = segments.sublist(libIndex).join('/');
    } else if (segments.isNotEmpty) {
      location = segments.last;
    }
  }
  return location;
}

/// Parses a [StackTrace] into normalized frames.
///
/// [keepLineNumbers] is true for display (you want to jump to the line) and
/// false for fingerprinting (you want stability across edits).
List<StackFrame> parseStackTrace(
  StackTrace? stackTrace, {
  bool keepLineNumbers = true,
  int maxFrames = 12,
}) {
  if (stackTrace == null) return const [];
  final frames = <StackFrame>[];

  for (final line in stackTrace.toString().split('\n')) {
    if (line.trim().isEmpty) continue;
    if (frames.length >= maxFrames) break;

    String member;
    String location;

    final dartMatch = _dartFrame.firstMatch(line);
    final jsMatch = dartMatch == null ? _jsFrame.firstMatch(line) : null;
    if (dartMatch != null) {
      member = dartMatch.group(1)!.trim();
      location = dartMatch.group(2)!.trim();
    } else if (jsMatch != null) {
      member = jsMatch.group(1)!.trim();
      location = jsMatch.group(2)!.trim();
    } else {
      // `<asynchronous suspension>` and friends.
      continue;
    }

    final isApp =
        !_noiseFrame.hasMatch(location) && !location.startsWith('dart:');
    frames.add(
      StackFrame(
        location:
            _normalizeLocation(location, keepLineNumbers: keepLineNumbers),
        member: member,
        isApp: isApp,
      ),
    );
  }
  return frames;
}

final RegExp _hexish = RegExp(r'\b[0-9a-f]{8,}\b', caseSensitive: false);
final RegExp _uuid = RegExp(
  r'\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b',
  caseSensitive: false,
);
final RegExp _number = RegExp(r'(?<![A-Za-z_])\d+(\.\d+)?');
final RegExp _quoted = RegExp('"[^"]*"' r"|'[^']*'");
final RegExp _url = RegExp(r'https?://\S+');
final RegExp _path = RegExp(r'(/[\w.-]+){2,}');
final RegExp _whitespace = RegExp(r'\s+');

/// Replaces the varying parts of a message with placeholders.
///
/// `Timeout after 3021ms for order 4471` and `Timeout after 12ms for order 9`
/// both normalize to `timeout after <n>ms for order <n>`, so they land in one
/// group instead of thousands.
String normalizeMessage(String message) {
  var normalized = message.toLowerCase();
  normalized = normalized.replaceAll(_url, '<url>');
  normalized = normalized.replaceAll(_uuid, '<uuid>');
  normalized = normalized.replaceAll(_quoted, '<str>');
  normalized = normalized.replaceAll(_path, '<path>');
  normalized = normalized.replaceAll(_hexish, '<hex>');
  normalized = normalized.replaceAll(_number, '<n>');
  normalized = normalized.replaceAll(_whitespace, ' ').trim();
  return normalized;
}

/// Computes the grouping key for an error occurrence.
///
/// The fingerprint is derived from the error type plus the first few
/// *application* frames (line numbers excluded). When no usable frame exists
/// it falls back to the normalized message, which still groups far better than
/// the raw text.
String errorFingerprint({
  required String errorType,
  required String message,
  StackTrace? stackTrace,
  int framesInFingerprint = 5,
}) =>
    errorFingerprintFromParsedFrames(
      errorType: errorType,
      message: message,
      frames: parseStackTrace(stackTrace, maxFrames: 40),
      framesInFingerprint: framesInFingerprint,
    );

/// [errorFingerprint] for a stack trace that has already been parsed.
///
/// Line numbers are stripped here rather than during parsing, so a caller
/// that also needs the frames for display can parse once and use the result
/// for both.
String errorFingerprintFromParsedFrames({
  required String errorType,
  required String message,
  required List<StackFrame> frames,
  int framesInFingerprint = 5,
}) {
  final appFrames = frames.where((f) => f.isApp).take(framesInFingerprint);
  final signature = StringBuffer(errorType);
  if (appFrames.isEmpty) {
    signature
      ..write('|')
      ..write(normalizeMessage(message));
  } else {
    for (final frame in appFrames) {
      signature
        ..write('|')
        ..write(frame.locationWithoutLineNumber)
        ..write('#')
        ..write(frame.member);
    }
  }
  return shortHash(signature.toString());
}

/// Fingerprint for an error whose frames are already plain strings rather
/// than a Dart [StackTrace] — e.g. one reconstructed from a non-Dart stack
/// trace forwarded over a platform channel from native (iOS/Android) code.
///
/// Frames are hashed as given, with no Dart-specific parsing or line-number
/// stripping; callers that build such frames (see `ailog_flutter`'s native
/// bridge) are expected to already have normalized them appropriately for
/// their platform.
String errorFingerprintFromFrames({
  required String errorType,
  required String message,
  List<String> frames = const [],
  int framesInFingerprint = 5,
}) {
  final signature = StringBuffer(errorType);
  if (frames.isEmpty) {
    signature
      ..write('|')
      ..write(normalizeMessage(message));
  } else {
    for (final frame in frames.take(framesInFingerprint)) {
      signature
        ..write('|')
        ..write(frame);
    }
  }
  return shortHash(signature.toString());
}
