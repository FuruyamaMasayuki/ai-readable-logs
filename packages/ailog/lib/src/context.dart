/// Ambient correlation context, propagated through [Zone]s.
///
/// The point of trace correlation is that call sites should not have to thread
/// a request id through fifteen function signatures. Anything logged inside
/// `runWithScope` — including from `await`ed continuations and callbacks
/// scheduled inside it — inherits the trace, span and context fields.
library;

import 'dart:async';

const Object _scopeKey = #ailog_scope;

/// Immutable correlation state for the current zone.
class LogScope {
  const LogScope({
    this.traceId,
    this.spanId,
    this.parentSpanId,
    this.fields = const {},
    this.tags = const [],
  });

  final String? traceId;
  final String? spanId;
  final String? parentSpanId;

  /// Context fields merged into every event logged inside this scope.
  final Map<String, Object?> fields;
  final List<String> tags;

  LogScope child({
    String? traceId,
    String? spanId,
    Map<String, Object?>? fields,
    List<String>? tags,
  }) =>
      LogScope(
        traceId: traceId ?? this.traceId,
        spanId: spanId ?? this.spanId,
        // Entering a new span makes the current span the parent.
        parentSpanId: spanId != null ? this.spanId : parentSpanId,
        fields: fields == null || fields.isEmpty
            ? this.fields
            : {...this.fields, ...fields},
        tags:
            tags == null || tags.isEmpty ? this.tags : [...this.tags, ...tags],
      );

  static const empty = LogScope();
}

/// The scope in effect for the current zone, or [LogScope.empty].
LogScope get currentScope {
  final scope = Zone.current[_scopeKey];
  return scope is LogScope ? scope : LogScope.empty;
}

/// Runs [body] with [scope] installed.
R runWithScope<R>(LogScope scope, R Function() body) =>
    runZoned(body, zoneValues: {_scopeKey: scope});

/// Runs [body] with [scope] installed and errors forwarded to [onError].
R? runWithScopeGuarded<R>(
  LogScope scope,
  R Function() body,
  void Function(Object error, StackTrace stack) onError,
) =>
    runZonedGuarded(body, onError, zoneValues: {_scopeKey: scope});
