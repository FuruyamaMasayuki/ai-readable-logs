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
      expect(digest.errorGroups.single.count, 5);
      expect(digest.errorGroups.single.fingerprint, 'abc123');
    });

    test('ranks error groups by descending count', () {
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
