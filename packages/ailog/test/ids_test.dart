import 'package:ailog/ailog.dart';
import 'package:test/test.dart';

void main() {
  group('fnv1a64Hex', () {
    test('is deterministic for the same input', () {
      expect(fnv1a64Hex('hello'), fnv1a64Hex('hello'));
    });

    test('differs for different inputs', () {
      expect(fnv1a64Hex('hello'), isNot(fnv1a64Hex('world')));
    });

    test('is always 16 lowercase hex digits', () {
      expect(fnv1a64Hex(''), matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(fnv1a64Hex('x' * 1000), matches(RegExp(r'^[0-9a-f]{16}$')));
    });

    test('matches the published FNV-1a 64 vectors', () {
      // These are the canonical values, not values captured from this
      // implementation — so they catch the algorithm drifting, not just it
      // changing. The empty string must yield the offset basis exactly.
      expect(fnv1a64Hex(''), 'cbf29ce484222325');
      expect(fnv1a64Hex('a'), 'af63dc4c8601ec8c');
      expect(fnv1a64Hex('foobar'), '85944171f73967e8');
    });

    test('is computed without 64-bit int literals, so it runs on web', () {
      // Regression: `0xcbf29ce484222325` as a literal is a *compile error*
      // under dart2js, which made the whole package unbuildable for web.
      // The values below were verified identical between the VM and a
      // dart2js build executed under node.
      expect(fnv1a64Hex('alice@example.com'), '67023fc4a7ff2a46');
      expect(fnv1a64Hex('日本語テキスト'), '595827bcb1ebca5e');
    });
  });

  group('IdGenerator secure-random fallback', () {
    test('construction never throws, whatever the runtime provides', () {
      // Regression: the fallback caught only UnsupportedError, but dart2js
      // on Node throws a raw JS `ReferenceError: self is not defined` from
      // Random.secure(). The narrower catch never fired, so merely
      // constructing a Logger crashed the program — the exact opposite of
      // "a logger must never break the program it observes". Found by
      // compiling for web and actually running the output under node.
      expect(IdGenerator.new, returnsNormally);
      expect(() => Logger.create(sink: MemorySink()), returnsNormally);
    });
  });

  group('shortHash', () {
    test('is deterministic', () {
      expect(shortHash('alice@example.com'), shortHash('alice@example.com'));
    });

    test('respects the requested length', () {
      expect(shortHash('x', length: 4), hasLength(4));
      expect(shortHash('x', length: 16), hasLength(16));
    });

    test('clamps length to the 1..16 range', () {
      expect(shortHash('x', length: 0), hasLength(1));
      expect(shortHash('x', length: 100), hasLength(16));
    });

    test('only ever emits lowercase hex characters', () {
      for (var i = 0; i < 500; i++) {
        expect(shortHash('input-$i', length: 16),
            matches(RegExp(r'^[0-9a-f]{16}$')));
      }
    });
  });

  group('IdGenerator', () {
    test('traceId is 32 lowercase hex characters (128 bits)', () {
      final id = IdGenerator().traceId();
      expect(id, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('spanId is 16 lowercase hex characters (64 bits)', () {
      final id = IdGenerator().spanId();
      expect(id, matches(RegExp(r'^[0-9a-f]{16}$')));
    });

    test('successive ids are (almost certainly) unique', () {
      final generator = IdGenerator();
      final ids = List.generate(200, (_) => generator.traceId()).toSet();
      expect(ids, hasLength(200));
    });
  });

  group('SequenceCounter', () {
    test('starts at 1 and increments by 1 each call', () {
      final counter = SequenceCounter();
      expect(counter.next(), 1);
      expect(counter.next(), 2);
      expect(counter.next(), 3);
    });

    test('current reflects the last issued value without advancing it', () {
      final counter = SequenceCounter();
      expect(counter.current, 0);
      counter.next();
      counter.next();
      expect(counter.current, 2);
      expect(counter.current, 2,
          reason: 'reading current must not advance the counter');
    });
  });
}
