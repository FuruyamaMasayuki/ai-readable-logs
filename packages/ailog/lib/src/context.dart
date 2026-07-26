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
  /// Creates a scope. `const`, so a fixed scope costs nothing to declare.
  ///
  /// Usually obtained from `Logger.startTrace` (which generates the id)
  /// rather than built by hand; construct one directly when adopting an id
  /// that came from somewhere else — an incoming request header, a job
  /// payload — so the log correlates with the system that issued it.
  const LogScope({
    this.traceId,
    this.spanId,
    this.parentSpanId,
    this.fields = const {},
    this.tags = const [],
  });

  /// The logical operation everything in this scope belongs to (`tr`).
  final String? traceId;

  /// The step within the trace (`sp`).
  final String? spanId;

  /// The enclosing step (`psp`), set automatically by [child] when a nested
  /// span is entered.
  final String? parentSpanId;

  /// Context fields merged into every event logged inside this scope.
  final Map<String, Object?> fields;

  /// Tags added to every event logged inside this scope.
  final List<String> tags;

  /// A scope derived from this one, for entering a nested span or adding
  /// fields.
  ///
  /// Omitted arguments inherit; [fields] and [tags] are merged rather than
  /// replaced, with the new values winning on a key collision. Passing
  /// [spanId] makes the current [spanId] the new scope's [parentSpanId], so
  /// nesting records itself.
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

  /// The scope in effect where none was installed: no trace, no fields.
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
