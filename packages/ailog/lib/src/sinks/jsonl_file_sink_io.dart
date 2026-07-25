import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../log_event.dart';
import '../log_level.dart';
import '../platform.dart';
import 'log_sink.dart';

/// Appends one JSON object per line to a file, with size-based rotation.
///
/// This is the artifact you hand to an AI: a single self-describing file whose
/// first line explains every key, followed by newline-delimited events that
/// can be streamed, `grep`ped, `jq`ed or chunked without a parser.
///
/// Writes go through an explicit in-memory buffer and a synchronous
/// [RandomAccessFile], rather than an [IOSink]. That is a deliberate choice
/// and worth knowing about:
///
/// * **Correctness.** Calling `IOSink.flush()` repeatedly on a handle from
///   `File.openWrite()` while more writes arrive between flushes silently
///   loses data — measured at 9 of 15 events lost in a loop with an `await`
///   between rounds, which is what every real request handler looks like.
///   Flushing eagerly on errors, which durability requires, makes that
///   pattern the norm rather than the exception.
/// * **Durability.** The buffer is written out synchronously, so it does not
///   depend on the event loop getting a turn. An `IOSink`'s timer-based flush
///   cannot run while the isolate is executing synchronous code — which
///   describes an infinite loop, a runaway computation, and the allocation
///   storm before an OOM kill, i.e. exactly the crashes the log exists for.
class JsonlFileSink implements LogSink {
  JsonlFileSink({
    required String path,
    this.maxBytes = 8 * 1024 * 1024,
    this.maxFiles = 5,
    this.flushInterval = const Duration(seconds: 2),
    this.writeSchemaHeader = true,
    this.flushOnErrorLevel = true,
    this.bufferBytes = 64 * 1024,
    this.onError,
  }) : _path = path {
    // A bad log path must not take down app startup: the same reasoning that
    // makes `add` swallow I/O errors applies here. The sink starts unhealthy
    // instead, and says so via [isHealthy] and [onError].
    try {
      _open();
    } catch (error, stackTrace) {
      _file = null;
      _report(error, stackTrace);
    }
    if (flushInterval > Duration.zero) {
      _flushTimer = Timer.periodic(flushInterval, (_) => _drain());
    }
  }

  final String _path;

  /// Rotate once the active file exceeds this size.
  final int maxBytes;

  /// How many rotated files to keep (`app.jsonl.1` … `app.jsonl.N`).
  final int maxFiles;

  /// How often buffered lines are written out. `Duration.zero` disables the
  /// timer, leaving it to [bufferBytes], [flushOnErrorLevel] and [flush].
  final Duration flushInterval;

  /// Whether to write the schema legend as the first line of a new file.
  final bool writeSchemaHeader;

  /// Whether `error`/`fatal` events are written out immediately.
  ///
  /// Buffered lines are lost if the process dies — including, typically, the
  /// very event that explains why. For a package built around post-mortem
  /// analysis that is the worst thing to lose, so errors bypass the buffer by
  /// default.
  final bool flushOnErrorLevel;

  /// How much is buffered before being written out.
  final int bufferBytes;

  /// Called when a filesystem operation fails.
  ///
  /// Every I/O error here is swallowed so logging can never break the host
  /// program, but silence has its own cost: a sink whose reopen failed drops
  /// events forever, and "my logs just stop after a while" is an unfixable
  /// bug report. This is the escape hatch — surface it somewhere you'll see.
  final void Function(Object error, StackTrace stackTrace)? onError;

  RandomAccessFile? _file;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  int _bytesWritten = 0;
  Timer? _flushTimer;
  bool _closed = false;
  int _droppedEvents = 0;

  /// Path of the file currently being written.
  String get path => _path;

  /// Whether the sink currently has somewhere to write.
  ///
  /// False after a failed open or reopen, when events are being dropped.
  bool get isHealthy => !_closed && _file != null;

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
    _file = file.openSync(mode: FileMode.append);

    if (writeSchemaHeader && _bytesWritten == 0) {
      _appendLine({
        '_hdr': true,
        'schema': aiLogSchemaVersion,
        'generator': 'ailog',
        'startedAt': DateTime.now().toUtc().toIso8601String(),
        // OS, Dart version, pid and locale, written once per file rather
        // than merged into every event. "Reproduces only on Linux with Dart
        // 3.9" is a conclusion a model can only reach if the log says which
        // platform produced it — but the answer is identical on every line,
        // and putting it there costs 133 bytes per event (measured: a file
        // of 100 events grew 73%, from 182 to 315 bytes per line). Once, in
        // the header, is where invariant facts belong.
        'platform': platformContext(),
        'legend': schemaLegend(),
      });
    }
  }

  void _appendLine(Map<String, Object?> json) {
    late final String line;
    try {
      line = jsonEncode(json);
    } catch (_) {
      // The sanitizer should have made this impossible; degrade rather than
      // dropping the event entirely.
      line = jsonEncode({
        'ts': DateTime.now().toUtc().toIso8601String(),
        'lvl': 'warn',
        'msg': 'ailog: event could not be encoded',
        'lg': 'ailog',
      });
    }
    final bytes = utf8.encode('$line\n');
    _buffer.add(bytes);
    _bytesWritten += bytes.length;
  }

  /// Writes the buffer out. Synchronous on purpose — see the class doc.
  void _drain() {
    if (_buffer.isEmpty) return;
    final file = _file;
    if (file == null) {
      _buffer.clear();
      return;
    }
    try {
      file.writeFromSync(_buffer.takeBytes());
    } catch (error, stackTrace) {
      _buffer.clear();
      _report(error, stackTrace);
    }
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
      if (_file == null) {
        _droppedEvents++;
        return;
      }
      _appendLine(event.toJson());
      if (_buffer.length >= bufferBytes ||
          (flushOnErrorLevel &&
              event.level.severity >= LogLevel.error.severity)) {
        _drain();
      }
    } catch (error, stackTrace) {
      _droppedEvents++;
      _report(error, stackTrace);
    }
  }

  void _rotate() {
    // Everything buffered belongs to the file about to be rotated away.
    _drain();
    try {
      _file?.closeSync();
    } catch (_) {
      // Best effort.
    }
    _file = null;

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
      // Reopening failed (disk full, directory removed). Leave `_file` null:
      // `add` then counts dropped events instead of throwing on every call,
      // and `isHealthy` reports the degradation.
      _file = null;
      _report(error, stackTrace);
    }
  }

  @override
  Future<void> flush() async {
    _drain();
    try {
      _file?.flushSync();
    } catch (error, stackTrace) {
      _report(error, stackTrace);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _flushTimer?.cancel();
    _flushTimer = null;

    _drain();
    final file = _file;
    _file = null;
    try {
      file?.flushSync();
      file?.closeSync();
    } catch (_) {
      // Best effort.
    }
  }
}
