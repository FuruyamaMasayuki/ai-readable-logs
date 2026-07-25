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
    if (value is Uri) return _string(value.toString());
    if (value is Enum) return value.name;

    if (depth >= limits.maxDepth) return _string(value.toString());

    if (value is Iterable) {
      if (!seen.add(value)) return '<circular>';
      try {
        final items = <Object?>[];
        var count = 0;
        for (final item in value) {
          if (count >= limits.maxListItems) {
            final total = value is List ? value.length : null;
            items.add(total == null
                ? '…more items'
                : '…+${total - count} more items');
            break;
          }
          items.add(_sanitize(item, depth + 1, seen));
          count++;
        }
        return items;
      } finally {
        seen.remove(value);
      }
    }

    if (value is Map) {
      if (!seen.add(value)) return '<circular>';
      try {
        final result = <String, Object?>{};
        var count = 0;
        for (final entry in value.entries) {
          if (count >= limits.maxMapEntries) {
            result['…'] = '+${value.length - count} more fields';
            break;
          }
          final key = entry.key.toString();
          result[key] = redactor.isSensitiveKey(key)
              ? redactor.redactValueOfSensitiveKey(entry.value)
              : _sanitize(entry.value, depth + 1, seen);
          count++;
        }
        return result;
      } finally {
        seen.remove(value);
      }
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

    return _string(value.toString());
  }

  String _string(String value) {
    final redacted = redactor.redactString(value);
    if (redacted.length <= limits.maxStringLength) return redacted;
    final kept = redacted.substring(0, limits.maxStringLength);
    return '$kept…+${redacted.length - limits.maxStringLength} chars';
  }
}
