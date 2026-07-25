import 'package:ailog/ailog.dart';
import 'package:test/test.dart';

void main() {
  group('normalizeMessage', () {
    test('replaces numbers, urls and quoted strings with placeholders', () {
      final result = normalizeMessage(
        'Timeout after 3021ms calling https://api.example.com/v2/orders/44 for "order-44"',
      );
      expect(result, contains('<n>ms'));
      expect(result, contains('<url>'));
      expect(result, contains('<str>'));
      expect(result, isNot(contains('3021')));
    });

    test('two structurally identical messages normalize identically', () {
      final a = normalizeMessage('Timeout after 3021ms for order 4471');
      final b = normalizeMessage('Timeout after 12ms for order 9');
      expect(a, b);
    });
  });

  group('errorFingerprint', () {
    test('same error type and app frames produce the same fingerprint', () {
      final stack1 = StackTrace.fromString(
        '#0      Cart.checkout (package:app/checkout/cart.dart:42:5)\n'
        '#1      main (package:app/main.dart:10:3)\n',
      );
      final stack2 = StackTrace.fromString(
        '#0      Cart.checkout (package:app/checkout/cart.dart:99:1)\n'
        '#1      main (package:app/main.dart:20:1)\n',
      );

      final fp1 = errorFingerprint(
        errorType: 'StateError',
        message: 'Bad state: order 44 not found',
        stackTrace: stack1,
      );
      final fp2 = errorFingerprint(
        errorType: 'StateError',
        message: 'Bad state: order 99 not found',
        stackTrace: stack2,
      );

      expect(fp1, fp2,
          reason: 'line numbers and message details must not split the group');
    });

    test('different app frames produce different fingerprints', () {
      final stack1 = StackTrace.fromString(
        '#0      Cart.checkout (package:app/checkout/cart.dart:42:5)\n',
      );
      final stack2 = StackTrace.fromString(
        '#0      Payment.charge (package:app/payment/pay.dart:12:1)\n',
      );

      final fp1 = errorFingerprint(
          errorType: 'StateError', message: 'x', stackTrace: stack1);
      final fp2 = errorFingerprint(
          errorType: 'StateError', message: 'x', stackTrace: stack2);
      expect(fp1, isNot(fp2));
    });

    test('falls back to normalized message when there is no stack trace', () {
      final fp1 = errorFingerprint(
          errorType: 'StateError', message: 'order 44 missing');
      final fp2 = errorFingerprint(
          errorType: 'StateError', message: 'order 99 missing');
      expect(fp1, fp2);
    });
  });

  group('errorFingerprintFromFrames', () {
    test('same type and frames produce the same fingerprint', () {
      final fp1 = errorFingerprintFromFrames(
        errorType: 'NSException',
        message: 'crash 1',
        frames: const ['AppDelegate.didFinishLaunching(App.swift:42)'],
      );
      final fp2 = errorFingerprintFromFrames(
        errorType: 'NSException',
        message: 'crash 2',
        frames: const ['AppDelegate.didFinishLaunching(App.swift:42)'],
      );
      expect(fp1, fp2,
          reason: 'message differences must not affect the fingerprint');
    });

    test('different frames produce different fingerprints', () {
      final fp1 = errorFingerprintFromFrames(
        errorType: 'NSException',
        message: 'x',
        frames: const ['A.method(A.swift:1)'],
      );
      final fp2 = errorFingerprintFromFrames(
        errorType: 'NSException',
        message: 'x',
        frames: const ['B.method(B.swift:2)'],
      );
      expect(fp1, isNot(fp2));
    });

    test('falls back to the normalized message when there are no frames', () {
      final fp1 = errorFingerprintFromFrames(
          errorType: 'E', message: 'order 44 missing');
      final fp2 = errorFingerprintFromFrames(
          errorType: 'E', message: 'order 99 missing');
      expect(fp1, fp2);
    });

    test('does not run frames through Dart stack trace parsing', () {
      // A frame in an arbitrary native format must be hashed verbatim, not
      // rejected or altered the way parseStackTrace would treat unknown
      // lines.
      final fp = errorFingerprintFromFrames(
        errorType: 'E',
        message: 'x',
        frames: const ['some.native.Format#withoutDartConventions'],
      );
      expect(fp, isNotEmpty);
    });
  });

  group('parseStackTrace', () {
    test('marks SDK frames as non-app', () {
      final stack = StackTrace.fromString(
        '#0      Cart.checkout (package:app/checkout/cart.dart:42:5)\n'
        '#1      _CustomZone.run (dart:async/zone.dart:1000:19)\n',
      );
      final frames = parseStackTrace(stack);
      expect(frames[0].isApp, isTrue);
      expect(frames[1].isApp, isFalse);
    });

    test('respects maxFrames', () {
      final lines = List.generate(
        20,
        (i) => '#$i      f$i (package:app/a.dart:$i:1)',
      ).join('\n');
      final frames =
          parseStackTrace(StackTrace.fromString(lines), maxFrames: 5);
      expect(frames.length, 5);
    });
  });
}
