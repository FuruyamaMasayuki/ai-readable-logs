import 'package:ailog/src/digest_cli.dart';
import 'package:test/test.dart';

void main() {
  group('DigestCliOptions.parse', () {
    test('defaults to markdown, 20 max groups, stdout output', () {
      final options = DigestCliOptions.parse(['app.jsonl'])!;
      expect(options.paths, ['app.jsonl']);
      expect(options.format, DigestOutputFormat.markdown);
      expect(options.maxGroups, 20);
      expect(options.outputPath, isNull);
      expect(options.showHelp, isFalse);
    });

    test('collects multiple input paths', () {
      final options = DigestCliOptions.parse(['a.jsonl', 'b.jsonl'])!;
      expect(options.paths, ['a.jsonl', 'b.jsonl']);
    });

    test('--format json selects the JSON format', () {
      final options = DigestCliOptions.parse(['a.jsonl', '--format', 'json'])!;
      expect(options.format, DigestOutputFormat.json);
    });

    test('--format markdown and --format md both select markdown', () {
      expect(
        DigestCliOptions.parse(['a.jsonl', '--format', 'markdown'])!.format,
        DigestOutputFormat.markdown,
      );
      expect(
        DigestCliOptions.parse(['a.jsonl', '--format', 'md'])!.format,
        DigestOutputFormat.markdown,
      );
    });

    test('--format with an unknown value fails to parse', () {
      expect(DigestCliOptions.parse(['a.jsonl', '--format', 'yaml']), isNull);
    });

    test('--format without a value fails to parse', () {
      expect(DigestCliOptions.parse(['a.jsonl', '--format']), isNull);
    });

    test('--max-groups sets the limit', () {
      final options = DigestCliOptions.parse(['a.jsonl', '--max-groups', '5'])!;
      expect(options.maxGroups, 5);
    });

    test('--max-groups rejects zero, negative and non-numeric values', () {
      expect(DigestCliOptions.parse(['a.jsonl', '--max-groups', '0']), isNull);
      expect(DigestCliOptions.parse(['a.jsonl', '--max-groups', '-1']), isNull);
      expect(
          DigestCliOptions.parse(['a.jsonl', '--max-groups', 'many']), isNull);
    });

    test('-o and --output both set the output path', () {
      expect(DigestCliOptions.parse(['a.jsonl', '-o', 'out.md'])!.outputPath,
          'out.md');
      expect(
        DigestCliOptions.parse(['a.jsonl', '--output', 'out.json'])!.outputPath,
        'out.json',
      );
    });

    test('--output without a value fails to parse', () {
      expect(DigestCliOptions.parse(['a.jsonl', '--output']), isNull);
    });

    test('-h and --help set showHelp regardless of other arguments', () {
      expect(DigestCliOptions.parse(['-h'])!.showHelp, isTrue);
      expect(DigestCliOptions.parse(['--help'])!.showHelp, isTrue);
      expect(DigestCliOptions.parse([])!.showHelp, isFalse);
    });

    test('an unknown flag fails to parse', () {
      expect(DigestCliOptions.parse(['a.jsonl', '--bogus']), isNull);
    });

    test('parses combined options in any order', () {
      final options = DigestCliOptions.parse([
        '--format',
        'json',
        'a.jsonl',
        '--max-groups',
        '3',
        'b.jsonl',
        '-o',
        'out.json',
      ])!;
      expect(options.paths, ['a.jsonl', 'b.jsonl']);
      expect(options.format, DigestOutputFormat.json);
      expect(options.maxGroups, 3);
      expect(options.outputPath, 'out.json');
    });

    test('empty arguments parse successfully with no paths', () {
      final options = DigestCliOptions.parse([])!;
      expect(options.paths, isEmpty);
    });

    test('--format pretty selects the replay renderer', () {
      final options =
          DigestCliOptions.parse(['a.jsonl', '--format', 'pretty'])!;
      expect(options.format, DigestOutputFormat.pretty);
    });

    test('usage text documents pretty alongside the digest formats', () {
      // The flag is only discoverable through --help; if it falls out of the
      // usage string it effectively stops existing.
      expect(digestCliUsage, contains('pretty'));
    });
  });
}
