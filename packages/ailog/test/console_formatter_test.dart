import 'package:ailog/ailog.dart';
import 'package:test/test.dart';

LogEvent _event({
  String message = 'hello',
  LogLevel level = LogLevel.info,
  String logger = 'app',
  String? traceId,
  Map<String, Object?> context = const {},
  ErrorInfo? error,
  int? durationMs,
  List<Map<String, Object?>> chain = const [],
}) =>
    LogEvent(
      time: DateTime.utc(2026, 1, 1, 10, 30, 15, 250),
      level: level,
      message: message,
      logger: logger,
      sessionId: 's',
      sequence: 1,
      traceId: traceId,
      context: context,
      error: error,
      durationMs: durationMs,
      chain: chain,
    );

void main() {
  group('ConsoleFormatter (no color)', () {
    const formatter = ConsoleFormatter(useColor: false);

    test('includes level, logger and message with no ANSI codes', () {
      final output = formatter.format(_event(message: 'checkout started'));
      expect(output, contains('INFO'));
      expect(output, contains('[app]'));
      expect(output, contains('checkout started'));
      expect(output, isNot(contains('\x1B[')));
    });

    test('includes a shortened trace id when present', () {
      final output = formatter.format(
        _event(traceId: 'abcdef0123456789abcdef0123456789'),
      );
      expect(output, contains('#abcdef01'));
      expect(output, isNot(contains('abcdef0123456789abcdef0123456789')));
    });

    test('omits the trace marker when there is no trace', () {
      final output = formatter.format(_event());
      expect(output, isNot(contains('#')));
    });

    test('showTraceId: false hides the trace id even when present', () {
      const noTraceFormatter =
          ConsoleFormatter(useColor: false, showTraceId: false);
      final output = noTraceFormatter.format(_event(traceId: 'a' * 32));
      expect(output, isNot(contains('#aaaaaaaa')));
    });

    test('appends duration when present', () {
      final output = formatter.format(_event(durationMs: 812));
      expect(output, contains('(812ms)'));
    });

    test('renders context as key=value pairs', () {
      final output = formatter.format(
        _event(context: {'requestId': 'r-1', 'itemCount': 3}),
      );
      expect(output, contains('requestId=r-1'));
      expect(output, contains('itemCount=3'));
    });

    test('renders error type, message and fingerprint on their own line', () {
      final output = formatter.format(
        _event(
          error: ErrorInfo(
            type: 'StateError',
            message: 'bad state',
            fingerprint: 'deadbeef',
            frames: const ['a.dart:1 main', 'b.dart:2 helper'],
          ),
        ),
      );
      expect(output, contains('StateError: bad state'));
      expect(output, contains('[fp:deadbeef]'));
      expect(output, contains('at a.dart:1 main'));
      expect(output, contains('at b.dart:2 helper'));
    });

    test('truncates frame list beyond 6 with a visible marker', () {
      final frames = List.generate(10, (i) => 'frame$i.dart:1 fn');
      final output = formatter.format(
        _event(
          error: ErrorInfo(
            type: 'E',
            message: 'm',
            fingerprint: 'fp',
            frames: frames,
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        expect(output, contains('frame$i.dart'));
      }
      expect(output, contains('+4 more frames'));
    });

    test('renders the causal chain with relative offsets', () {
      final output = formatter.format(
        _event(
          chain: const [
            {'dt': -120, 'lvl': 'info', 'msg': 'step one'},
            {'dt': -30, 'lvl': 'debug', 'msg': 'step two'},
          ],
        ),
      );
      expect(output, contains('causal chain (2 events)'));
      expect(output, contains('-120ms  step one'));
      expect(output, contains('-30ms  step two'));
    });
  });

  group('ConsoleFormatter (color)', () {
    const formatter = ConsoleFormatter(useColor: true);

    test('wraps the level tag in ANSI escape codes', () {
      final output = formatter.format(_event(level: LogLevel.error));
      expect(output, contains('\x1B['));
      expect(output, contains('ERROR'));
    });
  });
}
