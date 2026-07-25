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
