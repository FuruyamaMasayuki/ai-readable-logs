import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../log_event.dart';
import '../log_level.dart';
import 'log_sink.dart';

/// Appends one JSON object per line to a file, with size-based rotation.
///
/// This is the artifact you hand to an AI: a single self-describing file whose
/// first line explains every key, followed by newline-delimited events that
/// can be streamed, `grep`ped, `jq`ed or chunked without a parser.
class JsonlFileSink implements LogSink {
  JsonlFileSink({
    required String path,
    this.maxBytes = 8 * 1024 * 1024,
    this.maxFiles = 5,
    this.flushInterval = const Duration(seconds: 2),
    this.writeSchemaHeader = true,
    this.flushOnErrorLevel = true,
    this.onError,
  }) : _path = path {
    // A bad log path must not take down app startup: the same reasoning that
    // makes `add` swallow I/O errors applies here. The sink starts unhealthy
    // instead, and says so via [isHealthy] and [onError].
    try {
      _open();
    } catch (error, stackTrace) {
      _sink = null;
      _report(error, stackTrace);
    }
    if (flushInterval > Duration.zero) {
      _flushTimer = Timer.periodic(flushInterval, (_) {
        unawaited(flush());
      });
    }
  }

  final String _path;

  /// Rotate once the active file exceeds this size.
  final int maxBytes;

  /// How many rotated files to keep (`app.jsonl.1` … `app.jsonl.N`).
  final int maxFiles;

  /// How often buffered lines are pushed to disk. `Duration.zero` disables the
  /// timer, leaving flushing to the caller.
  final Duration flushInterval;

  /// Whether to write the schema legend as the first line of a new file.
  final bool writeSchemaHeader;

  /// Whether `error`/`fatal` events force an immediate flush.
  ///
  /// Writes are buffered and flushed on [flushInterval], so a process that
  /// dies takes the un-flushed tail with it — including, typically, the very
  /// event that explains why it died. For a package built around post-mortem
  /// analysis, losing that line is the worst possible failure, so it is
  /// flushed eagerly by default. Set this false if the extra syscall on every
  /// error is measurably too expensive.
  final bool flushOnErrorLevel;

  /// Called when a filesystem operation fails.
  ///
  /// Every I/O error here is swallowed so logging can never break the host
  /// program, but silence has its own cost: a sink whose reopen failed drops
  /// events forever, and "my logs just stop after a while" is an unfixable
  /// bug report. This is the escape hatch — surface it somewhere you'll see.
  final void Function(Object error, StackTrace stackTrace)? onError;

  IOSink? _sink;
  int _bytesWritten = 0;
  Timer? _flushTimer;
  bool _closed = false;
  int _droppedEvents = 0;

  /// Path of the file currently being written.
  String get path => _path;

  /// Whether the sink currently has somewhere to write.
  ///
  /// False after a failed open or reopen, when events are being dropped.
  bool get isHealthy => !_closed && _sink != null;

  /// How many events have been dropped because the sink was unhealthy.
  int get droppedEvents => _droppedEvents;

  void _report(Object error, StackTrace stackTrace) {
    try {
      onError?.call(error, stackTrace);
    } catch (_) {
      // A broken error handler must not escalate into a crash.
    }
  }

  void _open() {
    final file = File(_path);
    final directory = file.parent;
    if (!directory.existsSync()) directory.createSync(recursive: true);

    final existed = file.existsSync();
    _bytesWritten = existed ? file.lengthSync() : 0;
    _sink = file.openWrite(mode: FileMode.append);

    if (writeSchemaHeader && _bytesWritten == 0) {
      _writeLine({
        '_hdr': true,
        'schema': aiLogSchemaVersion,
        'generator': 'ailog',
        'startedAt': DateTime.now().toUtc().toIso8601String(),
        'legend': schemaLegend(),
      });
    }
  }

  void _writeLine(Map<String, Object?> json) {
    final sink = _sink;
    if (sink == null) return;
    late final String line;
    try {
      line = jsonEncode(json);
    } catch (_) {
      // Sanitizer should have made this impossible; degrade instead of
      // dropping the event entirely.
      line = jsonEncode({
        'ts': DateTime.now().toUtc().toIso8601String(),
        'lvl': 'warn',
        'msg': 'ailog: event could not be encoded',
        'lg': 'ailog',
      });
    }
    sink.writeln(line);
    // `+1` for the newline; utf8 length matters for rotation accuracy.
    _bytesWritten += utf8.encode(line).length + 1;
  }

  @override
  void add(LogEvent event) {
    if (_closed) return;
    // A logger must never break the program it is observing, so every
    // filesystem interaction below is contained here. Disk-full, a revoked
    // permission, or the log directory being deleted out from under us are
    // all real, and they tend to happen exactly when something is already
    // going wrong and the log matters most.
    try {
      if (_bytesWritten >= maxBytes) _rotate();
      if (_sink == null) {
        _droppedEvents++;
        return;
      }
      _writeLine(event.toJson());
      if (flushOnErrorLevel &&
          event.level.severity >= LogLevel.error.severity) {
        unawaited(flush());
      }
    } catch (error, stackTrace) {
      // Give up on this event rather than propagating into the caller.
      _droppedEvents++;
      _report(error, stackTrace);
    }
  }

  void _rotate() {
    final sink = _sink;
    _sink = null;
    // Close asynchronously; the new file is opened immediately so no event is
    // lost while the old handle drains.
    if (sink != null) unawaited(sink.close().catchError((_) {}));

    try {
      // Walks from the oldest slot to the newest so each rename target is
      // vacated before it is written to. i == maxFiles is the oldest kept
      // rotation and is dropped (overwritten) once a new one takes its place.
      for (var i = maxFiles; i >= 1; i--) {
        final source = File(i == 1 ? _path : '$_path.${i - 1}');
        if (!source.existsSync()) continue;
        source.renameSync('$_path.$i');
      }
    } catch (error, stackTrace) {
      // If rotation fails (permissions, a locked file on Windows) keep
      // logging into the existing file rather than losing events.
      _report(error, stackTrace);
    }

    try {
      _open();
    } catch (error, stackTrace) {
      // Reopening failed (disk full, directory removed). Leave `_sink` null:
      // `add` then counts dropped events instead of throwing on every call,
      // and `isHealthy` reports the degradation.
      _sink = null;
      _report(error, stackTrace);
    }
  }

  @override
  Future<void> flush() async {
    try {
      await _sink?.flush();
    } catch (_) {
      // Disk full or handle closed; the next write will surface it.
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    final sink = _sink;
    _sink = null;
    try {
      await sink?.flush();
      await sink?.close();
    } catch (_) {
      // Best effort.
    }
  }
}
