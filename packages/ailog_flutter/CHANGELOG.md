## 0.3.0

- **`AilogLifecycleObserver`** — foreground/background/termination, with both
  ends of each transition (`paused → resumed`). A handful of events over a
  session, and repeatedly decisive: "crashes when you come back to the app"
  is invisible in a log that only records what the code did. Defaults to
  `trace`, so it stays out of a production file while remaining available as
  a breadcrumb.
- User interaction logging documented, built on `ailog`'s new
  `logger.interaction()`. Deliberately **no** automatic "log every tap":
  measured against a real widget tree, a root `Listener` plus a hit test
  recovers a useful label only for text-labelled buttons — an `IconButton`
  yields "a button", a `TextField` nothing — while costing a hit test per
  pointer-down and carrying a privacy problem regex redaction cannot solve
  (semantic labels contain user data: a contacts row is labelled with a
  person's name). The README states this, with the numbers and a recipe for
  anyone who wants it anyway.
- `runAppGuarded` gains `capturePrint` / `forwardPrintsToConsole`: plain
  `print()` calls (yours or a dependency's) are routed into the structured
  log via `ailog`'s `capturePrints`.
- Depends on `ailog ^0.4.0` as a hosted dependency, making the package
  publishable; local development uses `pubspec_overrides.yaml`.

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
