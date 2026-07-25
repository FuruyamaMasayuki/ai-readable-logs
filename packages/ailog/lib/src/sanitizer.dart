/// Converts arbitrary Dart values into bounded, JSON-safe, redacted data.
///
/// Two jobs, both of which matter for AI consumption:
///
/// * **Safety** — `jsonEncode` throws on anything it does not recognise, and a
///   logger must never throw in the middle of someone's request handler.
/// * **Budget** — a 2 MB base64 blob in one field can eat an entire model
///   context window. Everything is truncated to a documented bound, and the
///   truncation is *visible* (`"…+12480 chars"`) so nothing looks complete
///   when it is not.
library;

import 'redaction.dart';

/// Size bounds applied to every logged value.
class SanitizerLimits {
  const SanitizerLimits({
    this.maxStringLength = 512,
    this.maxListItems = 20,
    this.maxMapEntries = 40,
    this.maxDepth = 5,
  });

  /// Bounds tuned for feeding whole files to a model.
  static const compact = SanitizerLimits(
    maxStringLength: 200,
    maxListItems: 8,
    maxMapEntries: 20,
    maxDepth: 4,
  );

  /// Bounds for local debugging, where context beats token count.
  static const verbose = SanitizerLimits(
    maxStringLength: 4000,
    maxListItems: 100,
    maxMapEntries: 200,
    maxDepth: 8,
  );

  final int maxStringLength;
  final int maxListItems;
  final int maxMapEntries;
  final int maxDepth;
}

/// Applies [Redactor] and [SanitizerLimits] to a value tree.
class Sanitizer {
  Sanitizer({Redactor? redactor, this.limits = const SanitizerLimits()})
      : redactor = redactor ?? Redactor();

  final Redactor redactor;
  final SanitizerLimits limits;

  /// Sanitizes a top-level context map.
  Map<String, Object?> sanitizeMap(Map<String, Object?>? input) {
    if (input == null || input.isEmpty) return const {};
    final result = <String, Object?>{};
    var count = 0;
    for (final entry in input.entries) {
      if (count >= limits.maxMapEntries) {
        result['…'] = '+${input.length - count} more fields';
        break;
      }
      result[entry.key] = sanitize(entry.value, key: entry.key);
      count++;
    }
    return result;
  }

  /// Sanitizes any value. [key] enables key-based masking of secrets.
  Object? sanitize(Object? value,
      {String? key, int depth = 0, Set<Object>? seen}) {
    if (key != null && redactor.isSensitiveKey(key)) {
      return redactor.redactValueOfSensitiveKey(value);
    }
    return _sanitize(value, depth, seen ?? Set.identity());
  }

  Object? _sanitize(Object? value, int depth, Set<Object> seen) {
    if (value == null) return null;

    if (value is bool) return value;
    if (value is num) {
      // NaN / Infinity are not valid JSON.
      if (value is double && (value.isNaN || value.isInfinite)) {
        return value.toString();
      }
      return value;
    }
    if (value is String) return _string(value);
    if (value is DateTime) return value.toUtc().toIso8601String();
    if (value is Duration) return '${value.inMilliseconds}ms';
    if (value is Uri) return _string(_safeToString(value));
    if (value is Enum) return value.name;

    if (depth >= limits.maxDepth) return _string(_safeToString(value));

    // Containers are recorded in `seen` and never un-recorded. Releasing them
    // after the subtree finished would only guard against true cycles, and
    // leave *shared* references — the same object reachable by two paths —
    // to be walked once per path. Since `maxDepth` and `maxMapEntries` bound
    // depth and breadth independently, never their product, a diamond-shaped
    // graph then expands to `maxMapEntries ^ maxDepth`: at the defaults,
    // 40^5 ≈ 10^8 entries from a handful of maps. That is not a hostile
    // input — an ORM entity graph whose children point back at a shared
    // parent, or a normalized cache, has exactly this shape, and one
    // `logger.info` would hang and then exhaust memory. Measured before this
    // change: 72 input entries produced 4.2 MiB in 460 ms at fan-out 12.
    //
    // Keeping them recorded makes output size linear in input size. The cost
    // is that a genuinely shared value renders once and then as `<seen>`.
    if (value is Iterable) {
      if (!seen.add(value)) return '<seen>';
      final items = <Object?>[];
      var count = 0;
      for (final item in value) {
        if (count >= limits.maxListItems) {
          final total = value is List ? value.length : null;
          items.add(
              total == null ? '…more items' : '…+${total - count} more items');
          break;
        }
        items.add(_sanitize(item, depth + 1, seen));
        count++;
      }
      return items;
    }

    if (value is Map) {
      if (!seen.add(value)) return '<seen>';
      final result = <String, Object?>{};
      var count = 0;
      for (final entry in value.entries) {
        if (count >= limits.maxMapEntries) {
          result['…'] = '+${value.length - count} more fields';
          break;
        }
        final key = _safeToString(entry.key as Object);
        result[key] = redactor.isSensitiveKey(key)
            ? redactor.redactValueOfSensitiveKey(entry.value)
            : _sanitize(entry.value, depth + 1, seen);
        count++;
      }
      return result;
    }

    // Anything with a `toJson()` (freezed, json_serializable, ...) is worth
    // trying before falling back to `toString()`.
    try {
      final dynamic dynamicValue = value;
      final encoded = dynamicValue.toJson();
      if (encoded != null && encoded is! String) {
        return _sanitize(encoded, depth + 1, seen);
      }
      if (encoded is String) return _string(encoded);
    } on NoSuchMethodError {
      // No toJson(); fall through.
    } catch (_) {
      // A broken toJson() must not break logging.
    }

    return _string(_safeToString(value));
  }

  /// Redacts and length-bounds a standalone string.
  ///
  /// Used for the fields that aren't part of the context map but still must
  /// respect the same budget — the log message itself, and an error's
  /// message and stack frames.
  String sanitizeText(String value) => _string(value);

  /// How much text past [SanitizerLimits.maxStringLength] is still scanned
  /// for secrets.
  ///
  /// Redaction can *shrink* the string — a 1700-character PEM block becomes a
  /// ~30-character placeholder — which pulls later content into the visible
  /// window. Scanning only up to `maxStringLength` would let that pulled-in
  /// text reach the output unscanned. This headroom covers realistic
  /// shrinkage (several full private keys) while keeping the work bounded.
  static const int _redactionHeadroom = 4096;

  String _string(String value) {
    // Redact a bounded prefix rather than the whole value. Output is capped
    // at maxStringLength regardless, so scanning a 50 KB response body in
    // full is work thrown away: measured at 6.3 ms per call, enough to drop
    // frames on a UI isolate. Everything that can reach the output is still
    // scanned — see [_redactionHeadroom].
    final scanLimit = limits.maxStringLength + _redactionHeadroom;
    final scanned =
        value.length > scanLimit ? value.substring(0, scanLimit) : value;
    final droppedBeforeRedaction = value.length - scanned.length;

    final redacted = redactor.redactString(scanned);
    if (droppedBeforeRedaction == 0 &&
        redacted.length <= limits.maxStringLength) {
      return redacted;
    }
    if (redacted.length <= limits.maxStringLength) {
      return '$redacted…+$droppedBeforeRedaction chars';
    }

    var cut = limits.maxStringLength;
    // Never split a `[redacted:kind#hash]` placeholder: a truncated
    // placeholder like `[redacted:ema` reads like leaked data rather than a
    // mask. If the cut lands inside one, pull back to just before it.
    final lastOpen = redacted.lastIndexOf('[redacted:', cut);
    if (lastOpen != -1) {
      final close = redacted.indexOf(']', lastOpen);
      if (close == -1 || close >= cut) cut = lastOpen;
    }

    final kept = redacted.substring(0, cut);
    // Report the true number of dropped characters, including whatever was
    // cut before scanning — otherwise the marker understates how much of the
    // value is missing.
    final dropped = redacted.length - cut + droppedBeforeRedaction;
    return '$kept…+$dropped chars';
  }
}

/// `toString()` where the object might not cooperate.
///
/// Anything reaching the sanitizer is caller data, and `toString()` is
/// caller code: a buggy override, an uninitialized `late` field, a getter
/// that throws. Left unguarded, passing such an object in `context:` took
/// the *host program* down from inside a `logger.info()` call — the precise
/// failure this package promises never to cause.
///
/// The marker names the exception type rather than swallowing it silently,
/// so the log says why a value is missing instead of just omitting it.
String _safeToString(Object value) {
  try {
    return value.toString();
  } catch (error) {
    // `runtimeType` comes from the runtime, not from the object's own code,
    // so reading it here cannot fail the same way.
    return '<toString() threw ${error.runtimeType}>';
  }
}
