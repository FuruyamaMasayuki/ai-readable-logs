import 'package:ailog/ailog.dart';
import 'package:test/test.dart';

/// A domain object with a broken `toString()`. Not contrived: a buggy
/// override, an uninitialized `late` field, or a getter that throws all
/// produce this, and objects like it get passed in `context:` constantly.
class _ThrowsOnToString {
  @override
  String toString() => throw StateError('toString exploded');
}

class _LateField {
  late final String value;

  @override
  String toString() => value; // LateError until `value` is assigned.
}

class _ThrowsOnToJson {
  Map<String, Object?> toJson() => throw StateError('toJson exploded');

  @override
  String toString() => 'fallback rendering';
}

void main() {
  // The package's central promise is that a logger never breaks the program
  // it observes. These are the cases that broke it: `toString()` is caller
  // code, so it can throw, and the value paths did not guard it.
  group('a value whose toString() throws', () {
    late MemorySink sink;
    late Logger logger;

    setUp(() {
      sink = MemorySink();
      logger = Logger.create(sink: sink);
    });

    test('in a context value: logged, not thrown', () {
      expect(
        () => logger.info('m', context: {'x': _ThrowsOnToString()}),
        returnsNormally,
      );
      expect(sink.events.single.context['x'], '<toString() threw StateError>');
    });

    test('as the thrown error itself: logged, not thrown', () {
      expect(
        () => logger.error(_ThrowsOnToString(), StackTrace.current),
        returnsNormally,
      );
      final error = sink.events.single.error!;
      expect(error.type, '_ThrowsOnToString');
      expect(error.message, contains('threw StateError'));
      expect(error.fingerprint, isNotEmpty,
          reason: 'grouping must still work for an unprintable error');
    });

    test('as a map key: logged, not thrown', () {
      expect(
        () => logger.info('m', context: {
          'inner': {_ThrowsOnToString(): 1},
        }),
        returnsNormally,
      );
      final inner = sink.events.single.context['inner'] as Map;
      expect(inner.keys.single, '<toString() threw StateError>');
    });

    test('nested past the depth limit: logged, not thrown', () {
      expect(
        () => logger.info('m', context: {
          'a': {
            'b': {
              'c': {'d': _ThrowsOnToString()},
            },
          },
        }),
        returnsNormally,
      );
      expect(sink.events, hasLength(1));
    });

    test('an uninitialized late field names LateError', () {
      logger.info('m', context: {'x': _LateField()});

      expect(sink.events.single.context['x'], '<toString() threw LateError>');
    });

    test('the marker names the exception rather than hiding the value', () {
      // Silently dropping the field would leave whoever reads the log
      // wondering whether it was never set; this says what happened.
      logger.info('m', context: {'x': _ThrowsOnToString()});

      expect(sink.events.single.context['x'], contains('StateError'));
    });
  });

  test('a throwing toJson() falls back to toString()', () {
    final sink = MemorySink();
    Logger.create(sink: sink).info('m', context: {'x': _ThrowsOnToJson()});

    expect(sink.events.single.context['x'], 'fallback rendering');
  });

  test('a self-referencing structure terminates', () {
    final sink = MemorySink();
    final cycle = <String, Object?>{};
    cycle['self'] = cycle;

    expect(
      () => Logger.create(sink: sink).info('m', context: {'c': cycle}),
      returnsNormally,
    );
    expect(sink.events, hasLength(1));
  });

  test('everything still serializes to valid JSONL afterwards', () {
    final sink = MemorySink();
    final logger = Logger.create(sink: sink);
    logger.info('a', context: {'x': _ThrowsOnToString()});
    logger.error(_ThrowsOnToString(), StackTrace.current);

    // The real test of containment: the file is still parseable.
    expect(digestFromJsonl(sink.toJsonl()).droppedEvents, 0);
  });
}
