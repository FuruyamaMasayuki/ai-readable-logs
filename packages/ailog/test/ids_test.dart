import 'package:ailog/ailog.dart';
import 'package:test/test.dart';

void main() {
  group('fnv1a64', () {
    test('is deterministic for the same input and seed', () {
      expect(fnv1a64('hello'), fnv1a64('hello'));
    });

    test('differs for different inputs', () {
      expect(fnv1a64('hello'), isNot(fnv1a64('world')));
    });

    test('differs for different seeds on the same input', () {
      expect(fnv1a64('hello'), isNot(fnv1a64('hello', seed: 42)));
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
