import 'dart:math';

/// Non-cryptographic 64-bit FNV-1a hash.
///
/// Used for error fingerprints and for the correlation tokens attached to
/// redacted values. It is fast, dependency free and stable across runs, which
/// is exactly what grouping needs. It is deliberately *not* used for anything
/// where collision resistance would be a security property.
int fnv1a64(String input, {int seed = 0xcbf29ce484222325}) {
  // 0x100000001b3, applied with explicit 64-bit wrapping semantics.
  const prime = 0x100000001b3;
  var hash = seed;
  for (var i = 0; i < input.length; i++) {
    hash ^= input.codeUnitAt(i);
    hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash;
}

/// Renders [fnv1a64] as a short lowercase hex token.
///
/// [int.toRadixString] prints a leading `-` for values whose top bit is set
/// (Dart ints are signed), which would corrupt the token. [BigInt] side-steps
/// that by treating the 64 bits as unsigned before rendering.
String shortHash(String input,
    {int seed = 0xcbf29ce484222325, int length = 8}) {
  final unsigned = BigInt.from(fnv1a64(input, seed: seed)).toUnsigned(64);
  final hex = unsigned.toRadixString(16).padLeft(16, '0');
  return hex.substring(0, length.clamp(1, 16));
}

/// Generates the random identifiers used for sessions, traces and spans.
///
/// Ids are lowercase hex so they stay cheap to tokenize and easy to grep.
class IdGenerator {
  IdGenerator({Random? random}) : _random = random ?? _secureOrFallback();

  final Random _random;

  static Random _secureOrFallback() {
    try {
      return Random.secure();
    } on UnsupportedError {
      // Some constrained runtimes have no secure source; ids are only used for
      // correlation, so a deterministic fallback is acceptable.
      return Random();
    }
  }

  /// A 128-bit id, used for sessions and traces.
  String traceId() => _hex(16);

  /// A 64-bit id, used for spans.
  String spanId() => _hex(8);

  String _hex(int bytes) {
    final buffer = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}

/// Process-wide monotonic counter for `seq`.
///
/// `seq` lets an analyzer restore the exact emission order even when several
/// events share a millisecond timestamp, or when files are merged.
class SequenceCounter {
  int _value = 0;

  int next() => ++_value;

  int get current => _value;
}
