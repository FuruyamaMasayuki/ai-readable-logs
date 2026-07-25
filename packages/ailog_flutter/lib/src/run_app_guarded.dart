/// The standard `main()` wiring: one zone, one trace, catches everything.
library;

import 'package:ailog/ailog.dart';

/// Runs [body] (which should call [WidgetsFlutterBinding.ensureInitialized]
/// and [runApp]) inside a [LogScope] with a zone-level catch-all, so that:
///
/// * every log call inside [body] — including ones made from async gaps and
///   framework callbacks — shares one trace id, and
/// * an error that would otherwise crash silently (uncaught in a callback,
///   outside any `try`/`catch`) is still recorded as `fatal` before it
///   propagates.
///
/// This mirrors the pattern crash-reporting SDKs (Crashlytics, Sentry)
/// recommend: initialize the binding and call `runApp` from *inside* the
/// guarded zone, not before it.
///
/// ```dart
/// void main() {
///   final logger = Logger.create(sink: ...);
///   AilogFlutter.install(logger);
///   runAppGuarded(logger, () {
///     WidgetsFlutterBinding.ensureInitialized();
///     runApp(const MyApp());
///   });
/// }
/// ```
void runAppGuarded(
  Logger logger,
  void Function() body, {
  LogScope? scope,
  Map<String, Object?>? context,
}) {
  runWithScopeGuarded(
    scope ?? logger.startTrace(context: context),
    body,
    (error, stack) {
      logger.fatal(error, stack,
          context: const {'source': 'zone'}, tags: const ['uncaught']);
    },
  );
}
