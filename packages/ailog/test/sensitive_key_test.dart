import 'package:ailog/ailog.dart';
import 'package:test/test.dart';

void main() {
  final redactor = Redactor(salt: 'fixed');

  group('isSensitiveKey — must match', () {
    const sensitive = [
      'password',
      'passwd',
      'pass',
      'Password',
      'userPassword',
      'secret',
      'clientSecret',
      'token',
      'accessToken',
      'refreshToken',
      'apiKey',
      'api_key',
      'API_KEY',
      'x-api-key',
      'authorization',
      'Authorization',
      'auth',
      'authToken',
      'credential',
      'userCredentials',
      'cookie',
      'sessionId',
      'session_id',
      'privateKey',
      'private_key',
      'accessKey',
      'signature',
      'pin',
      'PIN',
      'cvv',
      'otp',
      'mfa',
      'seedPhrase',
      'mnemonic',
    ];

    for (final key in sensitive) {
      test('"$key" is treated as sensitive', () {
        expect(redactor.isSensitiveKey(key), isTrue);
      });
    }
  });

  group('isSensitiveKey — must NOT match (regression: substring over-match)',
      () {
    // Every one of these was wholesale-redacted by the previous bare-substring
    // pattern: "pin" inside shipping/opinion/spinner, "auth" inside author.
    // Silently destroying ordinary fields defeats the purpose of a log meant
    // to be read and analyzed.
    const benign = [
      'shippingAddress',
      'shipping_address',
      'bookAuthor',
      'articleAuthorId',
      'coAuthorEmail',
      'opinionText',
      'spinnerValue',
      'pineapple',
      'napkinCount',
      'username',
      'userId',
      'email',
      'orderId',
      'itemCount',
      'requestId',
      'screen',
      'durationMs',
      'deliveryRequiredAtDoor',
    ];

    for (final key in benign) {
      test('"$key" is NOT treated as sensitive', () {
        expect(redactor.isSensitiveKey(key), isFalse);
      });
    }
  });

  group('sensitiveKeyWords', () {
    test('splits camelCase', () {
      expect(sensitiveKeyWords('refreshToken'), contains('refresh'));
      expect(sensitiveKeyWords('refreshToken'), contains('token'));
    });

    test('splits snake_case, kebab-case and dots', () {
      expect(sensitiveKeyWords('api_key'), containsAll(['api', 'key']));
      expect(sensitiveKeyWords('x-auth-token'),
          containsAll(['x', 'auth', 'token']));
      expect(sensitiveKeyWords('user.password'),
          containsAll(['user', 'password']));
    });

    test('emits adjacent pairs joined so multi-word secrets match', () {
      expect(sensitiveKeyWords('api_key'), contains('apikey'));
      expect(sensitiveKeyWords('private_key'), contains('privatekey'));
      expect(sensitiveKeyWords('sessionId'), contains('sessionid'));
    });

    test('lowercases everything', () {
      expect(sensitiveKeyWords('API_KEY'), contains('apikey'));
    });
  });

  group('custom sensitiveKeyPattern', () {
    test('an unanchored custom pattern still works as a substring test', () {
      final custom = Redactor(
        sensitiveKeyPattern: RegExp('internalId', caseSensitive: false),
      );
      expect(custom.isSensitiveKey('internalId'), isTrue);
      expect(custom.isSensitiveKey('myInternalIdField'), isTrue);
      expect(custom.isSensitiveKey('publicName'), isFalse);
    });

    test('an anchored custom pattern is matched per word, not per key', () {
      final custom = Redactor(
        sensitiveKeyPattern: RegExp(r'^ssn$', caseSensitive: false),
      );
      expect(custom.isSensitiveKey('ssn'), isTrue);
      expect(custom.isSensitiveKey('userSsn'), isTrue);
      // Must not fire on a key that merely contains the letters.
      expect(custom.isSensitiveKey('assnistant'), isFalse);
    });
  });

  group('end-to-end through Sanitizer', () {
    test('sensitive fields are masked, benign lookalikes are preserved', () {
      final sanitizer = Sanitizer(redactor: Redactor(salt: 'fixed'));
      final result = sanitizer.sanitizeMap({
        'refreshToken': 'abc123',
        'shippingAddress': '1-2-3 Shibuya',
        'bookAuthor': 'Ursula K. Le Guin',
        'password': 'hunter2',
      });

      expect(result['refreshToken'], contains('[redacted:field#'));
      expect(result['password'], contains('[redacted:field#'));
      expect(result['shippingAddress'], '1-2-3 Shibuya');
      expect(result['bookAuthor'], 'Ursula K. Le Guin');
    });
  });
}
