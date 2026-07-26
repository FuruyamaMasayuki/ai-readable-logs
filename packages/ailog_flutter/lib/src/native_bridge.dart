/// Wires the native (iOS/Android) side of an app into the same JSONL
/// output as the Dart side, over a dedicated [MethodChannel].
///
/// Two paths exist, matched to what native code can and cannot rely on:
///
/// * **Normal logging** — native code calls `Ailog.info/warn/error(...)`
///   (Kotlin) or `Ailog.info/warn/error(...)` (Swift), which invoke this
///   channel's `logEvent` method. [AilogNativeBridge] forwards it into the
///   Dart [Logger], so it goes through the same redaction, sanitization and
///   causal-chain machinery as any Dart-originated event, landing in the
///   same file.
/// * **Crash-time fallback** — an uncaught native exception may fire after
///   the Flutter engine has already torn down, when there is no channel to
///   send anything over. For that case only, the native side writes
///   directly to the JSONL file whose path this bridge pushes down via a
///   `configure` call (see [install]'s `logFilePath`). Those lines carry
///   their own native-generated `ses`/`seq` — they are a different writer,
///   not a continuation of the Dart session — but use the same field
///   names, so `ailog_digest` groups them by fingerprint like everything
///   else.
///
/// See the package README for the wire contract, platform limitations, and
/// how to call this from Kotlin/Swift.
library;

import 'dart:async';

import 'package:ailog/ailog.dart';
import 'package:flutter/services.dart';

/// Receives log events from Kotlin/Swift and writes them through a Dart
/// [Logger].
///
/// Created by [AilogNativeBridge.install]; the constructor is private
/// because installing is what wires up the [MethodChannel] handler, and a
/// bridge that is not listening does nothing.
class AilogNativeBridge {
  AilogNativeBridge._(this._channel, this._logger);

  final MethodChannel _channel;
  final Logger _logger;

  /// Installs the bridge.
  ///
  /// [logger] is the target every forwarded native event is written
  /// through — pass the same [Logger] the rest of the app uses so native
  /// and Dart events end up interleaved, correlated by timestamp, in one
  /// file.
  ///
  /// [logFilePath], when given, is sent to native code via a `configure`
  /// call so it knows where to append crash-time fallback lines. Pass the
  /// same path used to construct the app's `JsonlFileSink`. If native code
  /// doesn't implement the `configure` handler (or no platform plugin is
  /// registered — e.g. running on a platform without a native counterpart),
  /// the call fails silently; forwarding native→Dart logging still works.
  ///
  /// **Startup window**: `configure` is dispatched asynchronously and this
  /// method does not wait for it. Until it lands, the native side has no
  /// path to write to, so a native crash in that window is *not* captured by
  /// the crash-time fallback — it is dropped rather than written. The window
  /// is small (one platform-channel round trip) but real, and it overlaps
  /// exactly with early-startup native initialization, where crashes are
  /// relatively common. There is no way to close it from Dart: the engine
  /// must be up before any channel call is possible. Rely on a dedicated
  /// native crash reporter if early-startup crashes matter to you.
  ///
  /// Returns the bridge so callers can hold onto it for [dispose] or
  /// [requestNativeTestLog]; most apps can discard the return value.
  static AilogNativeBridge install(
    Logger logger, {
    String channelName = 'dev.ailog/flutter',
    String? logFilePath,
  }) {
    final channel = MethodChannel(channelName);
    final bridge = AilogNativeBridge._(channel, logger.child('native'));
    channel.setMethodCallHandler(bridge._handleCall);

    if (logFilePath != null) {
      unawaited(
        channel.invokeMethod<void>(
            'configure', {'logFilePath': logFilePath}).catchError((Object _) {
          // No-op: native side may not implement `configure` on this
          // platform (e.g. desktop/web with no plugin registered).
        }),
      );
    }
    return bridge;
  }

  /// Detaches the method call handler. Mostly useful in tests; a running
  /// app typically installs the bridge once for its whole lifetime.
  void dispose() {
    _channel.setMethodCallHandler(null);
  }

  /// Asks native code to emit one log event through the normal path, as a
  /// smoke test that the channel is wired up correctly in both directions.
  Future<void> requestNativeTestLog() =>
      _channel.invokeMethod<void>('emitTestLog').catchError((Object _) {});

  Future<Object?> _handleCall(MethodCall call) async {
    if (call.method != 'logEvent') return null;
    final args = _asStringKeyedMap(call.arguments);
    if (args == null) return null;
    try {
      _forward(args);
    } catch (error, stackTrace) {
      // A malformed payload from a hand-written native caller must not take
      // the channel handler down with it — and, since this *is* the logger,
      // the failure itself is worth a line rather than a silent drop.
      _logger.error(
        error,
        stackTrace,
        message: 'ailog: malformed native log event dropped',
        tags: const ['ailog-internal'],
      );
    }
    return null;
  }

  void _forward(Map<String, Object?> args) {
    // Everything below is read defensively: these values crossed a platform
    // channel from hand-written Kotlin/Swift, so a wrong type here is a
    // caller bug, not an invariant.
    final level = LogLevel.tryParse(_asString(args['level'])) ?? LogLevel.info;
    final message = args['message']?.toString() ?? '';
    final context = _asStringKeyedMap(args['context']);
    final tags = _asStringList(args['tags']);
    final durationMs = _asInt(args['durationMs']);
    final loggerName = _asString(args['logger']);
    final target = loggerName == null ? _logger : _logger.child(loggerName);

    final errorArgs = _asStringKeyedMap(args['error']);
    if (errorArgs == null) {
      target.log(level, message,
          context: context, tags: tags, durationMs: durationMs);
      return;
    }

    final type = errorArgs['type']?.toString() ?? 'Error';
    final errorMessage = errorArgs['message']?.toString() ?? message;
    final frames = _asStringList(errorArgs['frames']) ?? const <String>[];

    target.logError(
      ErrorInfo(
        type: type,
        message: errorMessage,
        fingerprint: errorFingerprintFromFrames(
          errorType: type,
          message: errorMessage,
          frames: frames,
        ),
        frames: frames,
      ),
      message: message.isEmpty ? null : message,
      context: context,
      tags: tags,
      level: level,
      durationMs: durationMs,
    );
  }

  Map<String, Object?>? _asStringKeyedMap(Object? value) {
    if (value is! Map) return null;
    return {
      for (final entry in value.entries) entry.key.toString(): entry.value,
    };
  }

  String? _asString(Object? value) =>
      value is String ? value : value?.toString();

  List<String>? _asStringList(Object? value) {
    if (value is! Iterable) return null;
    return value.map((e) => e.toString()).toList();
  }

  int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
