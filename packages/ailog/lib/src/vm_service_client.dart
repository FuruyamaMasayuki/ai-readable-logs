/// A minimal Dart VM Service client, built on `dart:io`'s `WebSocket`.
///
/// The VM Service speaks JSON-RPC 2.0 over a WebSocket, and `dart:io` ships a
/// WebSocket client — so the two calls `ailog_sync` needs (`getVM`, then the
/// registered extension) come to well under a hundred lines. Using
/// `package:vm_service` would be the obvious alternative and would cost this
/// package its zero-dependency property, which is a headline promise, for a
/// fraction of one library's surface.
///
/// VM-only, and deliberately not exported from `package:ailog/ailog.dart`:
/// this is the CLI's transport, not an API for applications.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A connected VM Service session.
class VmServiceClient {
  VmServiceClient._(this._socket) {
    _socket.listen(
      (data) {
        if (data is! String) return;
        final Object? decoded;
        try {
          decoded = jsonDecode(data);
        } on FormatException {
          return;
        }
        if (decoded is! Map) return;
        final id = decoded['id'];
        // Streamed events carry no id; only replies to our calls do.
        if (id is int) {
          _pending.remove(id)?.complete(decoded.cast<String, Object?>());
        }
      },
      onDone: _markClosed,
      onError: (Object _) => _markClosed(),
    );
  }

  final WebSocket _socket;
  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  int _nextId = 1;
  bool _closed = false;

  /// Whether the connection has ended.
  ///
  /// Becomes `true` when the app exits, is hot-restarted, or is detached
  /// from — which for a `--watch` caller is the normal end of a debugging
  /// session rather than a failure, and is why this is a state to poll and
  /// not only an exception to catch.
  bool get isClosed => _closed;

  /// Connects to a VM Service.
  ///
  /// [uri] is what `flutter run` or `dart run --observe` prints — an `http://`
  /// URL ending in a security token. The `ws://` WebSocket endpoint is derived
  /// from it, so either form may be passed.
  ///
  /// Throws [SocketException] if nothing is listening, which for a caller
  /// usually means the app is not running yet rather than anything being
  /// wrong.
  static Future<VmServiceClient> connect(Uri uri) async {
    final socket = await WebSocket.connect(webSocketUriFor(uri).toString());
    return VmServiceClient._(socket);
  }

  /// Calls [method] and returns its `result`.
  ///
  /// Throws [VmServiceException] when the VM replies with an `error`, which is
  /// how a missing service extension reports itself — the common case being an
  /// app that did not call `installDebugSync`.
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    // Writing to a closed WebSocket throws StateError, which is neither
    // catchable as a service error nor informative. Report it in the same
    // shape as every other failure here.
    if (_closed) throw VmServiceException(method, 'connection closed');

    final id = _nextId++;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _socket.add(jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    }));

    final reply = await completer.future;
    final result = reply['result'];
    if (result is Map) return result.cast<String, Object?>();

    final error = reply['error'];
    throw VmServiceException(
      method,
      error is Map ? error['message']?.toString() ?? '$error' : '$error',
      code: error is Map ? (error['code'] as num?)?.toInt() : null,
    );
  }

  /// The id of the app's main isolate, needed as a parameter on every
  /// extension call.
  ///
  /// Returns the first isolate the VM reports. A Flutter app's own code runs
  /// there; a background isolate that registered its own extension would need
  /// its id picked out of `getVM` by hand.
  Future<String?> mainIsolateId() async {
    final vm = await call('getVM');
    final isolates = vm['isolates'];
    if (isolates is! List || isolates.isEmpty) return null;
    final first = isolates.first;
    return first is Map ? first['id']?.toString() : null;
  }

  /// Closes the connection. Safe to call more than once.
  Future<void> close() async {
    await _socket.close();
    _markClosed();
  }

  void _markClosed() {
    _closed = true;
    final pending = _pending.values.toList();
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(
          const VmServiceException('', 'connection closed'),
        );
      }
    }
  }
}

/// Converts a VM Service URI into its WebSocket endpoint.
///
/// `http://127.0.0.1:8181/TOKEN=/` becomes `ws://127.0.0.1:8181/TOKEN=/ws`.
/// A URI that already points at `ws`/`wss` is returned with its scheme and
/// `/ws` suffix intact, so a caller may paste either form.
Uri webSocketUriFor(Uri uri) {
  final segments = [
    ...uri.pathSegments.where((segment) => segment.isNotEmpty),
  ];
  if (segments.isEmpty || segments.last != 'ws') segments.add('ws');
  return uri.replace(
    scheme: uri.scheme == 'https' || uri.scheme == 'wss' ? 'wss' : 'ws',
    pathSegments: segments,
  );
}

/// A JSON-RPC error returned by the VM Service.
class VmServiceException implements Exception {
  /// Creates an exception describing a failed [method] call.
  const VmServiceException(this.method, this.message, {this.code});

  /// The method that failed.
  final String method;

  /// The VM's error message.
  final String message;

  /// The JSON-RPC error code, when one was given.
  final int? code;

  @override
  String toString() => 'VmServiceException($method): $message';
}
