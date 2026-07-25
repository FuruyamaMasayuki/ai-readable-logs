/// Automatic masking of secrets and personal data.
///
/// Logs that are going to be pasted into an AI tool leave the machine, so
/// masking is a precondition rather than a nice-to-have. Every match is
/// replaced by a placeholder that carries a *correlation token*:
///
/// ```text
/// [redacted:email#3f2a1b8c]
/// ```
///
/// The token is a salted hash of the original value, so an analyst (human or
/// model) can still tell "the same user appears in these five lines" without
/// ever seeing the value. The salt is random per process by default, which
/// keeps the tokens meaningless outside a single log file.
library;

import 'dart:math';

import 'ids.dart';

/// One masking rule.
class RedactionRule {
  const RedactionRule({
    required this.name,
    required this.pattern,
    this.validate,
    this.requiresSubstring,
    this.enabledByDefault = true,
  });

  /// Label shown inside the placeholder, e.g. `email`.
  final String name;

  /// What to look for.
  final RegExp pattern;

  /// Optional second stage; a match is only redacted when this returns true.
  /// Used to keep false positives down (e.g. Luhn check for card numbers).
  final bool Function(String match)? validate;

  /// A literal that must appear for this rule to have any chance of matching.
  ///
  /// A `contains` scan is far cheaper than running the regex, and most
  /// strings contain no `@` and no `-----BEGIN`. Skipping those outright is
  /// the difference between paying for 13 regexes on every logged string and
  /// paying for the two or three that could plausibly fire.
  final String? requiresSubstring;

  /// Whether a default-constructed [Redactor] includes this rule.
  final bool enabledByDefault;
}

final RegExp _nonDigit = RegExp(r'\D');

bool _luhn(String candidate) {
  final digits = candidate.replaceAll(_nonDigit, '');
  if (digits.length < 13 || digits.length > 19) return false;
  var sum = 0;
  var double = false;
  for (var i = digits.length - 1; i >= 0; i--) {
    var digit = digits.codeUnitAt(i) - 0x30;
    if (double) {
      digit *= 2;
      if (digit > 9) digit -= 9;
    }
    sum += digit;
    double = !double;
  }
  return sum % 10 == 0;
}

/// The built-in rule set, ordered from most specific to most generic.
///
/// Specific rules run first so that, for example, a JWT is reported as a JWT
/// rather than being partially eaten by the generic high-entropy rule.
final List<RedactionRule> builtInRedactionRules = [
  RedactionRule(
    name: 'private_key',
    pattern: RegExp(
      r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----',
    ),
    // Without the END marker there is no match, but the lazy `[\s\S]*?`
    // still rescans to end-of-string for every BEGIN it finds. Requiring the
    // terminator up front makes an unterminated block free instead of
    // quadratic.
    requiresSubstring: '-----END',
  ),
  RedactionRule(
    name: 'jwt',
    pattern: RegExp(
        r'\beyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\b'),
    requiresSubstring: 'eyJ',
  ),
  RedactionRule(
    name: 'bearer',
    pattern: RegExp(r'(?<=[Bb]earer )[A-Za-z0-9._~+/=-]{8,}'),
  ),
  RedactionRule(
    name: 'basic_auth_url',
    pattern: RegExp(r'(?<=://)[^\s/:@]+:[^\s/@]+(?=@)'),
  ),
  RedactionRule(
    name: 'aws_key',
    pattern: RegExp(r'\b(?:AKIA|ASIA|AIDA|AROA)[0-9A-Z]{16}\b'),
  ),
  RedactionRule(
    name: 'gcp_key',
    pattern: RegExp(r'\bAIza[0-9A-Za-z_-]{35}\b'),
  ),
  RedactionRule(
    name: 'github_token',
    pattern: RegExp(r'\bgh[pousr]_[0-9A-Za-z]{20,}\b'),
  ),
  RedactionRule(
    name: 'slack_token',
    pattern: RegExp(r'\bxox[abprs]-[0-9A-Za-z-]{10,}\b'),
  ),
  RedactionRule(
    name: 'stripe_key',
    pattern: RegExp(r'\b(?:sk|pk|rk)_(?:live|test)_[0-9A-Za-z]{10,}\b'),
  ),
  RedactionRule(
    name: 'card',
    pattern: RegExp(r'\b(?:\d[ -]?){12,18}\d\b'),
    validate: _luhn,
  ),
  RedactionRule(
    name: 'email',
    // Both sides are length-bounded. `[A-Za-z]{2,}` for the TLD is the
    // textbook form and is unbounded-greedy: against
    // `alice@example.comSTATUS_OK` it consumes `comSTATUS` too, and against a
    // long run of letters it swallows the lot — one probe collapsed 4 KB of
    // text into a single placeholder. Over-redaction destroys exactly the
    // context this package exists to preserve, so cap each part at a length
    // no real address exceeds (RFC 5321 caps the local part at 64; the
    // longest live TLD is 24 characters).
    pattern: RegExp(
      r'\b[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,255}\.[A-Za-z]{2,24}\b',
    ),
    requiresSubstring: '@',
  ),
  RedactionRule(
    name: 'phone_jp',
    pattern: RegExp(r'\b0\d{1,4}-\d{1,4}-\d{3,4}\b|\b0[789]0\d{8}\b'),
  ),
  // Off by default: IP addresses are often the point of the log line.
  RedactionRule(
    name: 'ipv4',
    pattern: RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b'),
    enabledByDefault: false,
  ),
];

/// Field names whose *value* is masked regardless of what it looks like.
///
/// Matched against the key's individual *words*, not as a bare substring:
/// keys are split on camelCase boundaries, `_`, `-` and `.`, and each word is
/// tested. A bare substring match over-redacts badly — `pin` alone hits
/// `shippingAddress`, `spinnerValue` and `opinionText`; `auth` alone hits
/// `bookAuthor` and `coAuthorEmail` — and silently destroying ordinary
/// fields defeats the point of a log meant to be analyzed.
///
/// Short, ambiguous words (`pin`, `otp`, `mfa`, `cvv`) therefore only match
/// as whole words, while longer distinctive ones still match as prefixes of
/// a word (so `tokenValue` → word `token`, `refreshToken` → word `refresh`).
final RegExp defaultSensitiveKeyPattern = RegExp(
  // Trailing `s?` on the longer words so plurals (`credentials`, `secrets`,
  // `tokens`) match too.
  r'^(?:'
  r'pass(?:word|wd)?s?|secrets?|tokens?|apikeys?|auth(?:orization)?|'
  r'credentials?|cookies?|session|privatekeys?|accesskeys?|refresh|'
  r'signatures?|pin|cvv|otp|mfa|seedphrases?|mnemonics?'
  r')$',
  caseSensitive: false,
);

/// Splits a field name into comparable words: `refreshToken` → `[refresh,
/// token]`, `api_key` → `[api, key]`, `x-auth-token` → `[x, auth, token]`.
///
/// Adjacent word pairs are also emitted joined (`apikey`, `privatekey`,
/// `sessionid`) so multi-word secrets match without needing a separator in
/// the pattern.
List<String> sensitiveKeyWords(String key) {
  final parts = key
      .replaceAllMapped(
        RegExp(r'([a-z0-9])([A-Z])'),
        (m) => '${m[1]} ${m[2]}',
      )
      .split(RegExp(r'[\s_\-.]+'))
      .where((part) => part.isNotEmpty)
      .map((part) => part.toLowerCase())
      .toList();

  final words = <String>[...parts];
  for (var i = 0; i + 1 < parts.length; i++) {
    words.add('${parts[i]}${parts[i + 1]}');
  }
  return words;
}

/// Applies [RedactionRule]s to strings and to map keys.
class Redactor {
  Redactor({
    List<RedactionRule>? rules,
    RegExp? sensitiveKeyPattern,
    String? salt,
    this.correlationTokens = true,
  })  : rules = rules ??
            builtInRedactionRules.where((r) => r.enabledByDefault).toList(),
        sensitiveKeyPattern = sensitiveKeyPattern ?? defaultSensitiveKeyPattern,
        _salt = salt ?? _randomSalt();

  /// A redactor that masks nothing. Only appropriate for local experiments.
  factory Redactor.disabled() =>
      Redactor(rules: const [], sensitiveKeyPattern: RegExp(r'^$'));

  final List<RedactionRule> rules;
  final RegExp sensitiveKeyPattern;
  final String _salt;

  /// When false, placeholders omit the `#hash` suffix entirely.
  final bool correlationTokens;

  static String _randomSalt() {
    final random = Random();
    return List.generate(4, (_) => random.nextInt(1 << 30).toRadixString(16))
        .join();
  }

  String _placeholder(String kind, String value) {
    if (!correlationTokens) return '[redacted:$kind]';
    return '[redacted:$kind#${shortHash('$_salt|$value')}]';
  }

  /// Masks every rule match inside [input].
  String redactString(String input) {
    if (input.isEmpty) return input;
    var result = input;
    for (final rule in rules) {
      final required = rule.requiresSubstring;
      if (required != null && !result.contains(required)) continue;
      result = result.replaceAllMapped(rule.pattern, (match) {
        final matched = match.group(0)!;
        if (rule.validate != null && !rule.validate!(matched)) return matched;
        return _placeholder(rule.name, matched);
      });
    }
    return result;
  }

  /// Whether a structured field named [key] must be masked wholesale.
  ///
  /// The key is split into words first (see [sensitiveKeyWords]) so
  /// `refreshToken` and `api_key` match while `bookAuthor` and
  /// `shippingAddress` do not.
  ///
  /// A custom [sensitiveKeyPattern] that is not anchored (no `^`/`$`) still
  /// works as a plain substring test against the whole key — that keeps
  /// simple user-supplied patterns like `RegExp('internalId')` behaving the
  /// way they read.
  bool isSensitiveKey(String key) {
    final cached = _keyCache[key];
    if (cached != null) return cached;

    final result = _computeIsSensitiveKey(key);
    // Context keys come from a small fixed vocabulary in any real app, so
    // this caches essentially everything after warm-up. Uncached, splitting
    // and matching cost ~2.4 µs per key — around half the total cost of a
    // typical log call with a handful of context fields. The bound only
    // exists to stop a program that generates unbounded distinct keys (a map
    // keyed by request id, say) from growing this without limit.
    if (_keyCache.length >= _maxCachedKeys) _keyCache.clear();
    _keyCache[key] = result;
    return result;
  }

  static const int _maxCachedKeys = 1024;
  final Map<String, bool> _keyCache = {};

  bool _computeIsSensitiveKey(String key) {
    for (final word in sensitiveKeyWords(key)) {
      if (sensitiveKeyPattern.hasMatch(word)) return true;
    }
    // Unanchored custom patterns are also tried against the raw key.
    final source = sensitiveKeyPattern.pattern;
    if (!source.startsWith('^') && !source.endsWith(r'$')) {
      return sensitiveKeyPattern.hasMatch(key);
    }
    return false;
  }

  /// Masks the whole value of a sensitive field, keeping a correlation token
  /// so that "the token changed between these two requests" stays visible.
  String redactValueOfSensitiveKey(Object? value) =>
      _placeholder('field', value == null ? 'null' : value.toString());
}
