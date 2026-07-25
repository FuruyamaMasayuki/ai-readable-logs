import 'dart:convert';

import 'package:ailog/ailog.dart';
import 'package:test/test.dart';

void main() {
  group('shortHash', () {
    test('never emits a negative-looking token even when the top bit is set',
        () {
      // Regression: fnv1a64 can produce a value whose top bit is set, which
      // made int.toRadixString print a leading '-' before the fix.
      for (var i = 0; i < 2000; i++) {
        final hash = shortHash('probe-$i', length: 16);
        expect(hash, matches(RegExp(r'^[0-9a-f]{16}$')),
            reason: 'input probe-$i');
      }
    });
  });

  group('Redactor', () {
    test('masks email addresses with a stable correlation token', () {
      final redactor = Redactor(salt: 'fixed-salt');
      final first =
          redactor.redactString('contact me at alice@example.com please');
      final second = redactor.redactString('alice@example.com again');

      expect(first, contains('[redacted:email#'));
      expect(first, isNot(contains('alice@example.com')));

      final firstToken = RegExp(r'#([0-9a-f]+)\]').firstMatch(first)!.group(1);
      final secondToken =
          RegExp(r'#([0-9a-f]+)\]').firstMatch(second)!.group(1);
      expect(firstToken, secondToken,
          reason: 'same value must produce same token');
    });

    test('email masking does not swallow text after the address', () {
      // The TLD used to be `[A-Za-z]{2,}`, which is unbounded-greedy: it ate
      // trailing letters, and against a long run collapsed kilobytes of
      // context into one placeholder. Over-redaction destroys the very
      // context this package exists to preserve.
      //
      // Only the trailing side is fixable. `xxxalice@example.com` is a
      // syntactically valid address with a long local part, so text running
      // directly into the `@` is genuinely indistinguishable from part of the
      // address. In practice logged addresses are delimited by a quote,
      // space or `=`, which bounds the match anyway.
      final redactor = Redactor(salt: 'fixed');

      final adjacent = redactor.redactString('alice@example.comSTATUS_OK');
      expect(adjacent, contains('STATUS_OK'),
          reason: 'trailing context must survive');

      final delimited = redactor.redactString('user=alice@example.com ok');
      expect(delimited, startsWith('user='));
      expect(delimited, endsWith(' ok'));
    });

    test('a long run of letters is not treated as one giant address', () {
      final redactor = Redactor(salt: 'fixed');
      final result = redactor.redactString('a@b.${'c' * 500}');
      // The TLD cap means at most 24 trailing characters are consumed, so
      // the bulk of the run survives instead of vanishing.
      expect(result.length, greaterThan(400));
    });

    test('normal addresses are still fully masked', () {
      final redactor = Redactor(salt: 'fixed');
      for (final address in [
        'alice@example.com',
        'a.b+tag@sub.domain.co.jp',
        'first_last@my-company.io',
      ]) {
        final result = redactor.redactString('contact $address today');
        expect(result, isNot(contains(address)), reason: address);
        expect(result, contains('[redacted:email#'), reason: address);
      }
    });

    test('different values produce different tokens', () {
      final redactor = Redactor(salt: 'fixed-salt');
      final a = redactor.redactString('alice@example.com');
      final b = redactor.redactString('bob@example.com');
      expect(a, isNot(equals(b)));
    });

    test('masks bearer tokens', () {
      final redactor = Redactor();
      final result =
          redactor.redactString('Authorization: Bearer abc123.def456-ghi');
      expect(result, contains('[redacted:bearer#'));
      expect(result, isNot(contains('abc123.def456-ghi')));
    });

    test('masks JWTs', () {
      final redactor = Redactor();
      const jwt =
          'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U';
      final result = redactor.redactString('token=$jwt');
      expect(result, contains('[redacted:jwt#'));
      expect(result, isNot(contains(jwt)));
    });

    test('masks GitHub tokens', () {
      final redactor = Redactor();
      final result =
          redactor.redactString('ghp_1234567890abcdefghijklmnopqrstuvwx');
      expect(result, contains('[redacted:github_token#'));
    });

    test('validates card numbers with Luhn before redacting', () {
      final redactor = Redactor();
      // Valid Luhn test number.
      final valid = redactor.redactString('card 4111 1111 1111 1111 charged');
      expect(valid, contains('[redacted:card#'));

      // Invalid checksum: sixteen digits that fail Luhn should pass through.
      final invalid =
          redactor.redactString('order id 1234567890123456 created');
      expect(invalid, isNot(contains('[redacted:card')));
    });

    test('does not redact IPv4 by default', () {
      final redactor = Redactor();
      final result = redactor.redactString('connected from 192.168.1.10');
      expect(result, contains('192.168.1.10'));
    });

    test('correlationTokens: false omits the hash suffix', () {
      final redactor = Redactor(correlationTokens: false);
      final result = redactor.redactString('alice@example.com');
      expect(result, '[redacted:email]');
    });

    test('isSensitiveKey matches common secret field names', () {
      final redactor = Redactor();
      expect(redactor.isSensitiveKey('password'), isTrue);
      expect(redactor.isSensitiveKey('api_key'), isTrue);
      expect(redactor.isSensitiveKey('Authorization'), isTrue);
      expect(redactor.isSensitiveKey('username'), isFalse);
    });

    test('Redactor.disabled masks nothing', () {
      final redactor = Redactor.disabled();
      final result =
          redactor.redactString('alice@example.com password=hunter2');
      expect(result, 'alice@example.com password=hunter2');
    });
  });

  group('Sanitizer', () {
    test('redacts sensitive map keys wholesale', () {
      final sanitizer = Sanitizer(redactor: Redactor(salt: 's'));
      final result = sanitizer.sanitizeMap({
        'username': 'alice',
        'password': 'hunter2',
        'apiKey': 'sk_live_abcdef1234567890',
      });
      expect(result['username'], 'alice');
      expect(result['password'], contains('[redacted:field#'));
      expect(result['apiKey'], contains('[redacted:field#'));
    });

    test('truncates long strings with a visible marker', () {
      final sanitizer = Sanitizer(
        redactor: Redactor.disabled(),
        limits: const SanitizerLimits(maxStringLength: 10),
      );
      final result = sanitizer.sanitize('0123456789ABCDEF');
      expect(result, '0123456789…+6 chars');
    });

    test('bounds list length', () {
      final sanitizer = Sanitizer(
        redactor: Redactor.disabled(),
        limits: const SanitizerLimits(maxListItems: 3),
      );
      final result = sanitizer.sanitize([1, 2, 3, 4, 5]) as List;
      expect(result, [1, 2, 3, '…+2 more items']);
    });

    test('never truncates in the middle of a redaction placeholder', () {
      // A cut landing inside `[redacted:email#abc123]` would leave something
      // like `[redacted:ema`, which reads like leaked data rather than a
      // mask. The truncation must pull back to before the placeholder.
      final sanitizer = Sanitizer(
        redactor: Redactor(salt: 'fixed'),
        limits: const SanitizerLimits(maxStringLength: 20),
      );

      for (var padding = 0; padding < 30; padding++) {
        final input = '${'x' * padding}alice@example.com and more text here';
        final result = sanitizer.sanitizeText(input);
        final openCount = '[redacted:'.allMatches(result).length;
        final closeCount = ']'.allMatches(result).length;
        expect(
          closeCount,
          greaterThanOrEqualTo(openCount),
          reason:
              'padding=$padding produced an unterminated placeholder: $result',
        );
      }
    });

    test('sanitizeText bounds a standalone string like context values', () {
      final sanitizer = Sanitizer(
        redactor: Redactor.disabled(),
        limits: const SanitizerLimits(maxStringLength: 10),
      );
      expect(sanitizer.sanitizeText('0123456789ABCDEF'), '0123456789…+6 chars');
    });

    test('handles circular references without throwing', () {
      final sanitizer = Sanitizer(redactor: Redactor.disabled());
      final map = <String, Object?>{'name': 'root'};
      map['self'] = map;
      final result = sanitizer.sanitize(map) as Map;
      expect(result['self'], '<seen>');
    });

    test('a shared reference is not re-walked into an exponential blowup', () {
      // A diamond-shaped graph — children pointing back at one shared parent —
      // is what an ORM entity graph or a normalized cache looks like. It has
      // no cycle and needs no hostile input, but re-walking each path made
      // output grow as maxMapEntries^maxDepth: measured at 4.2 MiB from 72
      // input entries, and at the defaults that is ~10^8 entries, i.e. one
      // `logger.info` that hangs and then exhausts memory.
      Map<String, Object?> level = {'leaf': 1};
      for (var depth = 0; depth < 5; depth++) {
        final shared = level;
        level = {for (var i = 0; i < 40; i++) 'k$i': shared};
      }

      final sanitizer = Sanitizer(redactor: Redactor.disabled());
      final encoded = jsonEncode(sanitizer.sanitizeMap({'body': level}));

      expect(encoded.length, lessThan(50000),
          reason: 'output must stay linear in input size');
      expect(encoded, contains('<seen>'));
    });

    test('structurally equal but distinct values both render in full', () {
      // The de-duplication is by identity, so two separate maps that happen
      // to be equal must not be collapsed — that would lose real data.
      final sanitizer = Sanitizer(redactor: Redactor.disabled());
      final result = sanitizer.sanitizeMap({
        'a': {'x': 1},
        'b': {'x': 1},
      });
      expect(result['a'], {'x': 1});
      expect(result['b'], {'x': 1});
    });

    test('falls back to toJson() for custom objects', () {
      final sanitizer = Sanitizer(redactor: Redactor.disabled());
      final result = sanitizer.sanitize(_Point(1, 2)) as Map;
      expect(result, {'x': 1, 'y': 2});
    });
  });
}

class _Point {
  _Point(this.x, this.y);
  final int x;
  final int y;
  Map<String, Object?> toJson() => {'x': x, 'y': y};
}
