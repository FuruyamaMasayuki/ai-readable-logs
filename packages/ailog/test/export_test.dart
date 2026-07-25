import 'dart:convert';

import 'package:ailog/ailog.dart';
import 'package:test/test.dart';

LogEvent _event({
  required String message,
  String logger = 'app',
  LogLevel level = LogLevel.info,
  String? traceId,
  int seconds = 0,
  Map<String, Object?> context = const {},
  ErrorInfo? error,
}) =>
    LogEvent(
      time: DateTime.utc(2026, 1, 1, 0, 0, seconds),
      level: level,
      message: message,
      logger: logger,
      sessionId: 's',
      sequence: seconds,
      traceId: traceId,
      context: context,
      error: error,
    );

/// The scenario that motivated every aggregate in the digest: a lease is
/// taken on every request but only returned on the miss path, so the leak is
/// invisible in any single request and provable only by counting.
List<LogEvent> _poolLeak() {
  final events = <LogEvent>[];
  var leased = 0;
  var second = 0;
  for (var i = 1; i <= 10; i++) {
    events.add(_event(
        message: 'GET /product/$i',
        logger: 'http',
        traceId: 't$i',
        seconds: second++));
    leased++;
    events.add(_event(
        message: 'lease acquired',
        logger: 'pool',
        level: LogLevel.debug,
        traceId: 't$i',
        seconds: second++,
        context: {'leased': leased, 'max': 4}));
    if (i % 2 == 0) {
      events.add(_event(
          message: 'cache hit',
          logger: 'cache',
          traceId: 't$i',
          seconds: second++));
    } else {
      leased--;
      events.add(_event(
          message: 'lease released',
          logger: 'pool',
          level: LogLevel.debug,
          traceId: 't$i',
          seconds: second++,
          context: {'leased': leased}));
    }
  }
  events.add(_event(
    message: 'request failed',
    logger: 'http',
    level: LogLevel.error,
    traceId: 't11',
    seconds: second++,
    error: ErrorInfo(
        type: 'PoolTimeout', message: 'no connection', fingerprint: 'fp1'),
  ));
  return events;
}

void main() {
  group('message shapes', () {
    test('counts acquires and releases separately', () {
      final digest = buildDigest(_poolLeak());
      final shapes = {
        for (final s in digest.messageShapes) '${s.logger}|${s.shape}': s.count
      };

      expect(shapes['pool|lease acquired'], 10);
      expect(shapes['pool|lease released'], 5);
      expect(shapes['cache|cache hit'], 5);
    });

    test('groups messages that differ only by a number', () {
      final digest = buildDigest(_poolLeak());
      final get = digest.messageShapes
          .firstWhere((s) => s.logger == 'http' && s.shape.startsWith('get'));

      expect(get.count, 10, reason: 'GET /product/1..10 is one shape, not ten');
    });

    test('renders the mismatch in Markdown', () {
      final markdown = buildDigest(_poolLeak()).toMarkdown();

      expect(markdown, contains('`lease acquired` ×10'));
      expect(markdown, contains('`lease released` ×5'));
    });

    test('shapes are bounded so a log of unique lines cannot exhaust memory',
        () {
      final builder = DigestBuilder();
      for (var i = 0; i < DigestBuilder.maxShapes + 250; i++) {
        // Non-numeric, so normalization cannot merge them.
        builder.addEvent(_event(message: 'unique-shape-${_word(i)}'));
      }
      final digest = builder.build();

      expect(digest.messageShapes.length, DigestBuilder.maxShapes);
      expect(digest.unshapedEvents, 250);
      expect(digest.toMarkdown(), contains('missing from these counts'),
          reason: 'a truncated count must not read as a complete one');
    });

    test('records the highest level seen for a shape', () {
      final digest = buildDigest([
        _event(message: 'flaky', level: LogLevel.info),
        _event(message: 'flaky', level: LogLevel.error),
        _event(message: 'flaky', level: LogLevel.info),
      ]);

      final shape = digest.messageShapes.firstWhere((s) => s.shape == 'flaky');
      expect(shape.count, 3);
      expect(shape.level, LogLevel.error);
    });
  });

  group('numeric context fields', () {
    test('reports a counter exceeding the limit logged beside it', () {
      final digest = buildDigest(_poolLeak());
      final leased = digest.numericFields.firstWhere((f) => f.key == 'leased');
      final max = digest.numericFields.firstWhere((f) => f.key == 'max');

      expect(leased.max, greaterThan(max.max!),
          reason: 'the leak is exactly this: leased climbs past max');
      expect(digest.toMarkdown(), contains('`leased`: min='));
    });

    test('ignores non-numeric values', () {
      final digest = buildDigest([
        _event(message: 'm', context: {'name': 'alice', 'ok': true, 'n': 3}),
      ]);

      expect(digest.numericFields.map((f) => f.key), ['n']);
    });

    test('numeric keys are bounded', () {
      final builder = DigestBuilder();
      for (var i = 0; i < DigestBuilder.maxNumericFields + 20; i++) {
        builder.addEvent(_event(message: 'm', context: {'k$i': i}));
      }

      expect(
          builder.build().numericFields.length, DigestBuilder.maxNumericFields);
    });
  });

  group('digest honesty', () {
    test('names loggers that exist only inside causal chains', () {
      // The threshold kept `pool` lines out of the file, but its breadcrumbs
      // survived inside the error. Without a note this reads as the digest
      // contradicting itself.
      final event = LogEvent(
        time: DateTime.utc(2026),
        level: LogLevel.error,
        message: 'boom',
        logger: 'http',
        sessionId: 's',
        sequence: 1,
        error: ErrorInfo(type: 'E', message: 'boom', fingerprint: 'f'),
        chain: [
          {'dt': -5, 'lvl': 'debug', 'msg': 'lease acquired', 'lg': 'pool'},
        ],
      );

      final markdown = buildDigest([event]).toMarkdown();

      expect(markdown, contains('Not in this file: pool'));
      expect(markdown, contains('breadcrumbs'));
    });

    test('labels a group context as one sample of several', () {
      final events = [
        for (var i = 1; i <= 3; i++)
          _event(
            message: 'failed',
            level: LogLevel.error,
            traceId: 't$i',
            seconds: i,
            context: {'requestId': 'req-$i'},
            error: ErrorInfo(type: 'E', message: 'failed', fingerprint: 'f'),
          ),
      ];

      final markdown = buildDigest(events).toMarkdown();

      expect(markdown, contains('Context (first of 3): requestId=req-1'));
      expect(markdown, contains('Context (most recent): requestId=req-3'),
          reason: 'one sample invites the wrong conclusion about the group');
    });

    test('timestamps are UTC, matching the JSONL they came from', () {
      final digest = buildDigest([_event(message: 'm')]);
      expect(digest.toMarkdown(), contains('2026-01-01T00:00:00.000Z'));
    });
  });

  group('LogFilter', () {
    test('none keeps everything', () {
      final events = _poolLeak();
      final selection = LogFilter.none.apply(events);

      expect(selection.events, hasLength(events.length));
      expect(selection.droppedCount, 0);
    });

    test('collapseRepeats folds a run and records how many', () {
      final events = [
        _event(message: 'start', seconds: 0),
        for (var i = 1; i <= 50; i++)
          _event(message: 'polling for work', seconds: i),
        _event(message: 'done', seconds: 60),
      ];

      final selection = const LogFilter(collapseRepeats: true).apply(events);

      expect(selection.events.map((e) => e.message),
          ['start', 'polling for work', 'done']);
      expect(selection.events[1].context['repeated'], 50);
      expect(selection.events[1].tags, contains('collapsed'));
    });

    test('collapseRepeats only folds consecutive runs', () {
      final events = [
        _event(message: 'a', seconds: 0),
        _event(message: 'b', seconds: 1),
        _event(message: 'a', seconds: 2),
      ];

      final selection = const LogFilter(collapseRepeats: true).apply(events);

      expect(selection.events.map((e) => e.message), ['a', 'b', 'a'],
          reason: 'interleaving is part of what the log means');
    });

    test('aroundErrors keeps the events immediately before a failure', () {
      final events = [
        for (var i = 0; i < 40; i++) _event(message: 'noise $i', seconds: i),
        _event(message: 'boom', level: LogLevel.error, seconds: 40),
        for (var i = 41; i < 80; i++) _event(message: 'noise $i', seconds: i),
      ];

      final selection = const LogFilter(aroundErrors: 3).apply(events);

      expect(selection.events.map((e) => e.message), [
        'noise 37',
        'noise 38',
        'noise 39',
        'boom',
        'noise 41',
        'noise 42',
        'noise 43',
      ]);
      // 40 leading + 1 error + 39 trailing = 80 in, 7 kept.
      expect(selection.droppedBy['farFromError'], 73);
    });

    test('aroundErrors keeps everything when nothing failed', () {
      final events = [
        for (var i = 0; i < 10; i++) _event(message: 'noise $i', seconds: i),
      ];

      final selection = const LogFilter(aroundErrors: 2).apply(events);

      expect(selection.events, hasLength(10),
          reason: 'returning an empty log to someone investigating a non-error '
              'problem is the worst possible answer');
    });

    test('onlyFailedTraces keeps untraced errors rather than losing them', () {
      final events = [
        _event(message: 'ok', traceId: 'healthy', seconds: 0),
        _event(message: 'orphan failure', level: LogLevel.error, seconds: 1),
        _event(
            message: 'bad', level: LogLevel.error, traceId: 'sick', seconds: 2),
        _event(message: 'context', traceId: 'sick', seconds: 3),
      ];

      final selection = const LogFilter(onlyFailedTraces: true).apply(events);

      expect(selection.events.map((e) => e.message),
          ['orphan failure', 'bad', 'context']);
    });

    test('minimumLevel and logger filters compose, and each is counted', () {
      final events = [
        _event(message: 'a', level: LogLevel.debug, logger: 'http'),
        _event(message: 'b', level: LogLevel.info, logger: 'http'),
        _event(message: 'c', level: LogLevel.info, logger: 'db'),
      ];

      final selection = const LogFilter(
        minimumLevel: LogLevel.info,
        loggers: {'http'},
      ).apply(events);

      expect(selection.events.map((e) => e.message), ['b']);
      expect(selection.droppedBy, {'belowLevel': 1, 'otherLogger': 1});
    });

    test('maxEvents keeps the most recent', () {
      final events = [
        for (var i = 0; i < 10; i++) _event(message: 'm$i', seconds: i),
      ];

      final selection = const LogFilter(maxEvents: 3).apply(events);

      expect(selection.events.map((e) => e.message), ['m7', 'm8', 'm9']);
    });

    test('aggregates survive filtering that removes the evidence', () {
      // The whole point. `onlyFailedTraces` deletes every successful request,
      // and with it every unreturned lease — but the counts still show 10
      // acquires against 5 releases.
      final selection =
          const LogFilter(onlyFailedTraces: true).apply(_poolLeak());

      expect(selection.events.length, lessThan(5));
      final shapes = {
        for (final s in selection.digest.messageShapes)
          '${s.logger}|${s.shape}': s.count
      };
      expect(shapes['pool|lease acquired'], 10);
      expect(shapes['pool|lease released'], 5);
    });
  });

  group('string output', () {
    test('toJsonl round-trips through the same parser as the file', () {
      final events = _poolLeak();
      final jsonl = LogFilter.none.apply(events).toJsonl();

      final lines = const LineSplitter().convert(jsonl)
        ..removeWhere((l) => l.trim().isEmpty);
      expect(jsonDecode(lines.first)['_hdr'], true);

      final parsed = [
        for (final line in lines.skip(1))
          LogEvent.fromJson(jsonDecode(line) as Map<String, Object?>)
      ];
      expect(parsed.map((e) => e!.message), events.map((e) => e.message));
    });

    test('a filtered JSONL string says it was filtered', () {
      final jsonl = const LogFilter(maxEvents: 2)
          .apply(_poolLeak())
          .toJsonl(includeHeader: false);
      final first = jsonDecode(const LineSplitter().convert(jsonl).first)
          as Map<String, Object?>;

      expect(first['note'], contains('filtered:'));
      expect(first['droppedBy'], isNotEmpty);
      expect(first['_mix'], isNotEmpty,
          reason: 'the counts are what survives filtering; keep them inline');
    });

    test('digestFromJsonl reads back what toJsonl wrote', () {
      final jsonl = LogFilter.none.apply(_poolLeak()).toJsonl();
      final digest = digestFromJsonl(jsonl);

      expect(digest.totalEvents, _poolLeak().length);
      expect(digest.droppedEvents, 0,
          reason: 'the header line is recognised, not counted as garbage');
    });

    test('toReport carries both the aggregates and the raw events', () {
      final report = LogFilter.forAi.apply(_poolLeak()).toReport();

      expect(report, contains('# Log digest'));
      expect(report, contains('`lease acquired` ×10'));
      expect(report, contains('```jsonl'));
      expect(report, contains('"msg":"lease acquired"'));
    });

    test('MemorySink returns its contents as text', () {
      final sink = MemorySink();
      for (final event in _poolLeak()) {
        sink.add(event);
      }

      expect(sink.toJsonl(), contains('"msg":"lease acquired"'));
      expect(sink.toMarkdown(), contains('# Log digest'));
      expect(sink.export(LogFilter.forAi).events, isNotEmpty);
    });

    test('MemorySink text reflects only what capacity retained', () {
      final sink = MemorySink(capacity: 3);
      for (var i = 0; i < 10; i++) {
        sink.add(_event(message: 'm$i', seconds: i));
      }

      final lines = const LineSplitter()
          .convert(sink.toJsonl(includeHeader: false))
          .where((l) => l.trim().isNotEmpty);
      expect(lines, hasLength(3));
      expect(lines.last, contains('"msg":"m9"'));
    });
  });
}

/// Turns an integer into letters, so [normalizeMessage] cannot collapse the
/// results into a single numeric shape.
String _word(int n) {
  final buffer = StringBuffer();
  var value = n;
  do {
    buffer.writeCharCode(97 + value % 26);
    value ~/= 26;
  } while (value > 0);
  return buffer.toString();
}
