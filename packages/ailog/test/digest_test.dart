import 'package:ailog/ailog.dart';
import 'package:test/test.dart';

void main() {
  group('DigestBuilder', () {
    test('groups repeated errors by fingerprint and counts occurrences', () {
      final builder = DigestBuilder();
      for (var i = 0; i < 5; i++) {
        builder.addLine(
          '{"ts":"2026-01-01T00:00:0${i}Z","lvl":"error","msg":"boom $i",'
          '"lg":"app","ses":"s","seq":$i,'
          '"err":{"t":"StateError","m":"boom $i","fp":"abc123"}}',
        );
      }
      final digest = builder.build();

      expect(digest.totalEvents, 5);
      expect(digest.errorGroups, hasLength(1));
      expect(digest.errorGroups.single.occurrences, 5);
      expect(digest.errorGroups.single.fingerprint, 'abc123');
    });

    test('de-duplicates one failure logged at several layers of a trace', () {
      // The situation this exists for: `span()` records the failure passing
      // through it, then the caller catches the same exception at a boundary
      // and logs it again. Two log events, one actual failure. Counting them
      // as two would report the bug as twice as frequent as it is.
      final builder = DigestBuilder();
      void addError(String traceId, String logger, int seq) {
        builder.addLine(
          '{"ts":"2026-01-01T00:00:${seq.toString().padLeft(2, '0')}Z",'
          '"lvl":"error","msg":"x","lg":"$logger","ses":"s","seq":$seq,'
          '"tr":"$traceId","err":{"t":"E","m":"x","fp":"same"}}',
        );
      }

      // Two requests; each logs the same failure twice as it propagates.
      addError('trace-1', 'payment', 0);
      addError('trace-1', 'http', 1);
      addError('trace-2', 'payment', 2);
      addError('trace-2', 'http', 3);

      final group = builder.build().errorGroups.single;
      expect(group.occurrences, 4, reason: 'four log events were written');
      expect(group.incidents, 2, reason: 'but only two requests failed');
    });

    test('counts untraced events individually, since they cannot be grouped',
        () {
      final builder = DigestBuilder();
      for (var i = 0; i < 3; i++) {
        builder.addLine(
          '{"ts":"2026-01-01T00:00:0${i}Z","lvl":"error","msg":"x",'
          '"lg":"app","ses":"s","seq":$i,"err":{"t":"E","m":"x","fp":"f"}}',
        );
      }
      final group = builder.build().errorGroups.single;
      expect(group.incidents, 3);
      expect(group.occurrences, 3);
    });

    test('ranks by distinct failures, not by raw log volume', () {
      final builder = DigestBuilder();
      void addError(String fp, String traceId, int seq) {
        builder.addLine(
          '{"ts":"2026-01-01T00:00:${seq.toString().padLeft(2, '0')}Z",'
          '"lvl":"error","msg":"x","lg":"app","ses":"s","seq":$seq,'
          '"tr":"$traceId","err":{"t":"E","m":"x","fp":"$fp"}}',
        );
      }

      // "noisy" is logged 5 times but all within one request.
      for (var i = 0; i < 5; i++) {
        addError('noisy', 'trace-a', i);
      }
      // "widespread" is logged 3 times, but across three separate requests —
      // it is the more serious problem and must rank first.
      addError('widespread', 'trace-b', 5);
      addError('widespread', 'trace-c', 6);
      addError('widespread', 'trace-d', 7);

      final digest = builder.build();
      expect(digest.errorGroups.map((g) => g.fingerprint).toList(),
          ['widespread', 'noisy']);
      expect(digest.errorGroups.first.incidents, 3);
      expect(digest.errorGroups.last.incidents, 1);
      expect(digest.errorGroups.last.occurrences, 5);
    });

    test('incidents stay exact past the retained-trace-id sample bound', () {
      final builder = DigestBuilder();
      final total = ErrorGroup.maxRetainedTraceIds + 20;
      for (var i = 0; i < total; i++) {
        builder.addLine(
          '{"ts":"2026-01-01T00:00:00Z","lvl":"error","msg":"x","lg":"app",'
          '"ses":"s","seq":$i,"tr":"trace-$i",'
          '"err":{"t":"E","m":"x","fp":"f"}}',
        );
      }
      final group = builder.build().errorGroups.single;
      expect(group.incidents, total, reason: 'count must survive sampling');
      expect(group.traceIds.length, ErrorGroup.maxRetainedTraceIds,
          reason: 'but retained samples stay bounded');
    });

    test('ranks untraced error groups by descending count', () {
      final builder = DigestBuilder();
      void addError(String fp, int seq) {
        builder.addLine(
          '{"ts":"2026-01-01T00:00:${seq.toString().padLeft(2, '0')}Z","lvl":"error",'
          '"msg":"x","lg":"app","ses":"s","seq":$seq,'
          '"err":{"t":"E","m":"x","fp":"$fp"}}',
        );
      }

      addError('rare', 0);
      addError('common', 1);
      addError('common', 2);
      addError('common', 3);

      final digest = builder.build();
      expect(digest.errorGroups.map((g) => g.fingerprint).toList(),
          ['common', 'rare']);
    });

    test('skips header lines and counts unparsable lines as dropped', () {
      final builder = DigestBuilder();
      builder.addLine('{"_hdr":true,"schema":1}');
      builder.addLine('not json at all');
      builder.addLine(
        '{"ts":"2026-01-01T00:00:00Z","lvl":"info","msg":"ok","lg":"app","ses":"s","seq":1}',
      );

      final digest = builder.build();
      expect(digest.totalEvents, 1);
      expect(digest.droppedEvents, 1);
    });

    test('toMarkdown includes error type, count and fingerprint', () {
      final builder = DigestBuilder();
      builder.addLine(
        '{"ts":"2026-01-01T00:00:00Z","lvl":"error","msg":"x","lg":"app","ses":"s","seq":1,'
        '"err":{"t":"SocketException","m":"connection refused","fp":"deadbeef"}}',
      );
      final markdown = builder.build().toMarkdown();

      expect(markdown, contains('SocketException'));
      expect(markdown, contains('deadbeef'));
      expect(markdown, contains('×1'));
    });

    test('toJson respects maxGroups and reports truncation', () {
      final builder = DigestBuilder();
      for (var i = 0; i < 3; i++) {
        builder.addLine(
          '{"ts":"2026-01-01T00:00:0${i}Z","lvl":"error","msg":"x","lg":"app","ses":"s","seq":$i,'
          '"err":{"t":"E","m":"x","fp":"fp$i"}}',
        );
      }
      final json = builder.build().toJson(maxGroups: 2);
      expect((json['topErrors'] as List), hasLength(2));
      expect(json['truncatedGroups'], 1);
    });
  });
}
