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
    this.enabledByDefault = true,
  });

  /// Label shown inside the placeholder, e.g. `email`.
  final String name;

  /// What to look for.
  final RegExp pattern;

  /// Optional second stage; a match is only redacted when this returns true.
  /// Used to keep false positives down (e.g. Luhn check for card numbers).
  final bool Function(String match)? validate;

  /// Whether [Redactor.standard] includes this rule.
  final bool enabledByDefault;
}

bool _luhn(String candidate) {
  final digits = candidate.replaceAll(RegExp(r'\D'), '');
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
  ),
  RedactionRule(
    name: 'jwt',
    pattern: RegExp(
        r'\beyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\b'),
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
    pattern: RegExp(r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b'),
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
final RegExp defaultSensitiveKeyPattern = RegExp(
  r'pass(word|wd)?|secret|token|api[_-]?key|auth(orization)?|credential|'
  r'cookie|session[_-]?id|private[_-]?key|access[_-]?key|refresh|signature|'
  r'pin|cvv|otp|mfa|seed[_-]?phrase|mnemonic',
  caseSensitive: false,
);

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
      result = result.replaceAllMapped(rule.pattern, (match) {
        final matched = match.group(0)!;
        if (rule.validate != null && !rule.validate!(matched)) return matched;
        return _placeholder(rule.name, matched);
      });
    }
    return result;
  }

  /// Whether a structured field named [key] must be masked wholesale.
  bool isSensitiveKey(String key) => sensitiveKeyPattern.hasMatch(key);

  /// Masks the whole value of a sensitive field, keeping a correlation token
  /// so that "the token changed between these two requests" stays visible.
  String redactValueOfSensitiveKey(Object? value) =>
      _placeholder('field', value == null ? 'null' : value.toString());
}
