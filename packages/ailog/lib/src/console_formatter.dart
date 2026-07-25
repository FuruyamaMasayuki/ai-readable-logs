/// Human-readable rendering used by [ConsoleSink] during development.
///
/// The JSONL file is for machines; the terminal is for a person watching a
/// `dart run` scroll by. Colour and alignment matter here in a way they never
/// do in the file.
library;

import 'log_event.dart';
import 'log_level.dart';

const _reset = '\x1B[0m';
const _dim = '\x1B[2m';
const _bold = '\x1B[1m';

const Map<LogLevel, String> _levelColor = {
  LogLevel.trace: '\x1B[90m',
  LogLevel.debug: '\x1B[36m',
  LogLevel.info: '\x1B[32m',
  LogLevel.warn: '\x1B[33m',
  LogLevel.error: '\x1B[31m',
  LogLevel.fatal: '\x1B[97;41m',
};

/// Formats a [LogEvent] as one or more terminal lines.
class ConsoleFormatter {
  const ConsoleFormatter({this.useColor = true, this.showTraceId = true});

  final bool useColor;
  final bool showTraceId;

  String format(LogEvent event) {
    final buffer = StringBuffer();
    final time = _formatTime(event.time);
    final levelTag = event.level.wireName.toUpperCase().padRight(5);

    if (useColor) {
      final color = _levelColor[event.level] ?? '';
      buffer.write('$_dim$time$_reset ');
      buffer.write('$color$_bold$levelTag$_reset ');
      buffer.write('$_dim[${event.logger}]$_reset ');
    } else {
      buffer.write('$time $levelTag [${event.logger}] ');
    }

    if (showTraceId && event.traceId != null) {
      final shortTrace = event.traceId!.length > 8
          ? event.traceId!.substring(0, 8)
          : event.traceId!;
      buffer.write(useColor ? '$_dim#$shortTrace$_reset ' : '#$shortTrace ');
    }

    buffer.write(event.message);
    if (event.durationMs != null) buffer.write(' (${event.durationMs}ms)');

    if (event.context.isNotEmpty) {
      buffer.write(useColor
          ? ' $_dim${_renderContext(event.context)}$_reset'
          : ' ${_renderContext(event.context)}');
    }

    final error = event.error;
    if (error != null) {
      buffer.write(
          '\n  ${useColor ? '$_bold${error.type}$_reset' : error.type}: ${error.message}');
      buffer.write(useColor
          ? ' $_dim[fp:${error.fingerprint}]$_reset'
          : ' [fp:${error.fingerprint}]');
      for (final frame in error.frames.take(6)) {
        buffer.write('\n    at $frame');
      }
      if (error.frames.length > 6) {
        buffer.write('\n    … +${error.frames.length - 6} more frames');
      }
    }

    if (event.chain.isNotEmpty) {
      buffer.write(useColor
          ? '\n  $_dim— causal chain (${event.chain.length} events) —$_reset'
          : '\n  — causal chain (${event.chain.length} events) —');
      for (final entry in event.chain) {
        final dt = entry['dt'];
        final msg = entry['msg'];
        buffer.write('\n    ${dt}ms  $msg');
      }
    }

    return buffer.toString();
  }

  String _formatTime(DateTime time) {
    final local = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    String three(int n) => n.toString().padLeft(3, '0');
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}.${three(local.millisecond)}';
  }

  String _renderContext(Map<String, Object?> context) {
    final parts = context.entries.map((e) => '${e.key}=${e.value}');
    return parts.join(' ');
  }
}
