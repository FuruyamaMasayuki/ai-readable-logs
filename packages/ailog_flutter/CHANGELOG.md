## 0.2.0

- `ailog_flutter` is now a Flutter plugin (adds `android/` and `ios/`).
- `AilogNativeBridge`: forwards native (Kotlin `Ailog`, Swift `Ailog`) log
  calls into the Dart `Logger` over a `MethodChannel`, so native and Dart
  events share one JSONL file with the same redaction/sanitization.
- Android: `Ailog` Kotlin API plus a chained
  `Thread.setDefaultUncaughtExceptionHandler` that writes crash events
  directly to the configured JSONL path when the Flutter engine may
  already be gone.
- iOS: `Ailog` Swift API plus a chained `NSSetUncaughtExceptionHandler`
  with the same direct-write fallback (Objective-C `NSException` only —
  see the README for coverage limitations).
- `ailog`: added `Logger.logError` (log a pre-built `ErrorInfo`, e.g. from
  a non-Dart error) and `errorFingerprintFromFrames` (fingerprint an error
  from plain frame strings rather than a Dart `StackTrace`) to support the
  above.
- Example app: full `android`/`ios` platform scaffolding, plus a button
  demonstrating the native→Dart round trip.

## 0.1.0

- Initial release: `AilogFlutter.install` hooks for `FlutterError.onError`,
  `PlatformDispatcher.onError` and `ErrorWidget.builder` (all chaining any
  previously installed handler), `AilogNavigatorObserver` for route
  breadcrumbs, and `runAppGuarded` for zone-scoped `main()` wiring.
