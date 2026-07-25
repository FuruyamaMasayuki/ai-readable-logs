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
/// [capturePrint] additionally routes plain `print()` calls into [logger]
/// (tagged `print`), so un-migrated code and third-party packages show up in
/// the JSONL file too. [forwardPrintsToConsole] keeps the raw line visible
/// in the console; turn it off if a `ConsoleSink` is attached, or each print
/// appears twice.
void runAppGuarded(
  Logger logger,
  void Function() body, {
  LogScope? scope,
  Map<String, Object?>? context,
  bool capturePrint = false,
  bool forwardPrintsToConsole = true,
}) {
  void Function() wrapped = body;
  if (capturePrint) {
    wrapped = () => capturePrints(
          logger,
          body,
          forwardToConsole: forwardPrintsToConsole,
        );
  }
  runWithScopeGuarded(
    scope ?? logger.startTrace(context: context),
    wrapped,
    (error, stack) {
      logger.fatal(error, stack,
          context: const {'source': 'zone'}, tags: const ['uncaught']);
    },
  );
}
