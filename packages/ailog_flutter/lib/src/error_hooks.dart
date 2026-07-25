/// Wires Flutter's own error channels into an [ailog] [Logger].
///
/// Flutter already has three places errors surface — [FlutterError.onError]
/// for framework/build errors, [PlatformDispatcher.onError] for anything
/// that escapes a zone, and [ErrorWidget.builder] for what gets *shown* when
/// a widget fails to build. Each of them is opt-in here and, crucially, each
/// one **chains** whatever handler was already installed rather than
/// replacing it — so Crashlytics/Sentry/the default red screen keep working
/// exactly as before, with structured JSONL logging added alongside.
library;

import 'dart:ui' as ui;

import 'package:ailog/ailog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Installs the automatic Flutter error hooks.
///
/// Call this once, early in `main()` — typically right after
/// [WidgetsFlutterBinding.ensureInitialized]. See [runAppGuarded] for wiring
/// up the zone-level catch-all as well.
class AilogFlutter {
  AilogFlutter._();

  static bool _installed = false;

  /// Installs the hooks against [logger] (a `flutter` child logger is
  /// derived so these events are distinguishable from application logs).
  ///
  /// Calling this more than once is a no-op after the first call, since
  /// re-installing would chain the same handlers repeatedly and log each
  /// error twice.
  static void install(
    Logger logger, {
    bool recordFlutterErrors = true,
    bool recordPlatformDispatcherErrors = true,
    bool captureWidgetBuildErrors = true,
  }) {
    if (_installed) return;
    _installed = true;

    final flutterLogger = logger.child('flutter');

    if (recordFlutterErrors) {
      final previous = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        _record(flutterLogger, details, tags: const ['flutter-error']);
        previous?.call(details);
      };
    }

    if (recordPlatformDispatcherErrors) {
      final previous = ui.PlatformDispatcher.instance.onError;
      ui.PlatformDispatcher.instance.onError =
          (Object error, StackTrace stack) {
        flutterLogger.fatal(
          error,
          stack,
          context: const {'source': 'PlatformDispatcher'},
          tags: const ['uncaught'],
        );
        return previous?.call(error, stack) ?? false;
      };
    }

    if (captureWidgetBuildErrors) {
      final previousBuilder = ErrorWidget.builder;
      ErrorWidget.builder = (FlutterErrorDetails details) {
        _record(flutterLogger, details, tags: const ['widget-build']);
        return previousBuilder(details);
      };
    }
  }

  /// Resets installation state. Only meant for tests that need to reinstall
  /// hooks between cases.
  @visibleForTesting
  static void resetForTesting() => _installed = false;

  static void _record(
    Logger logger,
    FlutterErrorDetails details, {
    required List<String> tags,
  }) {
    final context = <String, Object?>{
      if (details.library != null) 'library': details.library,
      if (details.context != null) 'errorContext': details.context.toString(),
      'silent': details.silent,
    };
    logger.errorEvent(
      details.exception,
      details.stack,
      message: details.summary.toString(),
      context: context,
      tags: tags,
    );
  }
}
