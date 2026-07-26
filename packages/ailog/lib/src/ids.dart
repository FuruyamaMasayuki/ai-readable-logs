import 'dart:math';

/// 2^32 — the split point between the two halves of the 64-bit state.
const int _pow32 = 0x100000000;

// FNV-1a 64 constants (offset basis 0xcbf29ce484222325, prime 0x100000001b3),
// pre-split into 32-bit halves.
//
// Written this way because a 64-bit literal is a *compile error* under
// dart2js — "The integer literal can't be represented exactly in
// JavaScript" — which made the entire package fail to build for web rather
// than merely misbehave at runtime.
const int _basisHi = 0xcbf29ce4;
const int _basisLo = 0x84222325;
const int _primeHi = 0x00000100;
const int _primeLo = 0x000001b3;

/// Non-cryptographic 64-bit FNV-1a hash, as 16 lowercase hex digits.
///
/// Used for error fingerprints and for the correlation tokens attached to
/// redacted values. It is fast, dependency free and stable across runs, which
/// is exactly what grouping needs. It is deliberately *not* used for anything
/// where collision resistance would be a security property.
///
/// Returns a `String` rather than an `int` on purpose: a 64-bit value does not
/// fit in a web `int` (a double, exact only to 53 bits), so no `int`-returning
/// version can be correct on every platform this package targets. Hex is also
/// the form actually consumed — it goes straight into `fp` fields and
/// `[redacted:kind#hash]` tokens.
///
/// The arithmetic below uses `%` and `~/` rather than `&` and `>>`: bitwise
/// operators on values wider than 32 bits are exactly where VM and dart2js
/// semantics diverge, while plain arithmetic on values under 2^53 is exact on
/// both. Every intermediate product here stays under 2^53 — the largest is
/// (2^32 - 1) × 0x1b3 ≈ 1.9e12.
String fnv1a64Hex(String input) {
  var hi = _basisHi;
  var lo = _basisLo;

  for (var i = 0; i < input.length; i++) {
    // A UTF-16 code unit is at most 0xFFFF, so it only ever touches `lo`.
    lo ^= input.codeUnitAt(i);

    // (hi:lo) × (primeHi:primeLo) truncated to 64 bits. The hi × primeHi
    // term is dropped: it lands entirely above bit 63.
    final lowProduct = lo * _primeLo;
    final nextHi =
        (hi * _primeLo + lo * _primeHi + lowProduct ~/ _pow32) % _pow32;
    lo = lowProduct % _pow32;
    hi = nextHi;
  }

  return _hex8(hi) + _hex8(lo);
}

/// [fnv1a64Hex] truncated to [length] characters.
///
/// Truncation takes the high end, where FNV-1a's avalanche is strongest. The
/// default 8 characters (32 bits) is ample for grouping errors while staying
/// short enough to read inline in a log line.
String shortHash(String input, {int length = 8}) =>
    fnv1a64Hex(input).substring(0, length.clamp(1, 16));

String _hex8(int value) => value.toRadixString(16).padLeft(8, '0');

/// Generates the random identifiers used for sessions, traces and spans.
///
/// Ids are lowercase hex so they stay cheap to tokenize and easy to grep.
class IdGenerator {
  /// Creates a generator. Pass [random] only in tests, to make ids
  /// reproducible; the default uses a secure source where one exists.
  IdGenerator({Random? random}) : _random = random ?? _secureOrFallback();

  final Random _random;

  static Random _secureOrFallback() {
    try {
      return Random.secure();
    } catch (_) {
      // Some runtimes have no secure source; ids are only used for
      // correlation, so falling back is acceptable — and far better than
      // taking down the host program, which a logger must never do.
      //
      // Catching everything, not just UnsupportedError, is deliberate. Under
      // dart2js on Node this throws a raw JS `ReferenceError: self is not
      // defined` rather than an `UnsupportedError`, so the narrower catch
      // this replaced never fired: constructing a Logger crashed outright.
      // Found by compiling for web and actually running the output.
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

  /// Returns the next number, starting at 1.
  ///
  /// Starting at 1 rather than 0 is what makes loss computable: a file whose
  /// lowest `seq` is *n* is missing exactly *n − 1* earlier events. See
  /// `SequenceCoverage`.
  int next() => ++_value;

  /// The most recently issued number, or 0 before the first [next] call.
  int get current => _value;
}
