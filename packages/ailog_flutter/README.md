# ailog_flutter

Connects [`ailog`](../ailog) to a Flutter app. Automatically records the
framework's error channels (`FlutterError.onError`,
`PlatformDispatcher.onError`, `ErrorWidget.builder`) and navigation into the
same AI-readable JSONL output — and bridges native Kotlin/Swift code into it
too.

## Install

```sh
flutter pub add ailog ailog_flutter
```

Until the packages are on pub.dev, depend on them from the repository:

```yaml
dependencies:
  ailog:
    git:
      url: https://github.com/FuruyamaMasayuki/ai-readable-logs
      path: packages/ailog
  ailog_flutter:
    git:
      url: https://github.com/FuruyamaMasayuki/ai-readable-logs
      path: packages/ailog_flutter
```

## Setup

```dart
import 'package:ailog_flutter/ailog_flutter.dart';

void main() {
  final logFile = '${Directory.systemTemp.path}/ailog/app.jsonl';

  final logger = Logger.create(
    sink: MultiSink([
      JsonlFileSink(path: logFile),
      LevelFilterSink(ConsoleSink(), LogLevel.info),
    ]),
  );

  // Hooks FlutterError / PlatformDispatcher / ErrorWidget.
  // Existing handlers (Crashlytics, Sentry, …) are chained, never replaced.
  AilogFlutter.install(logger);

  // Optional: let native (Kotlin/Swift) code log into the same file.
  AilogNativeBridge.install(logger, logFilePath: logFile);

  runAppGuarded(logger, () {
    WidgetsFlutterBinding.ensureInitialized();
    runApp(const MyApp());
  });
}
```

`runAppGuarded` is the `runZonedGuarded` equivalent: every log call inside
`body` — including from async gaps and framework callbacks — shares one
trace, and anything that escapes uncaught is recorded as `fatal`.

### Capturing plain `print()`

```dart
runAppGuarded(
  logger,
  () { WidgetsFlutterBinding.ensureInitialized(); runApp(const MyApp()); },
  capturePrint: true,                   // print() → the JSONL file too
  forwardPrintsToConsole: true,         // and still visible in the console
);
```

Un-migrated code and third-party packages speak `print`, and none of it
reaches the log file otherwise. Captured lines are tagged `print` and carry
the ambient trace like any other event. Set `forwardPrintsToConsole: false`
if you attach a `ConsoleSink`, or each line appears twice.

### Console output on a device

`ConsoleSink` writes to `stdout` by default, which on a Flutter device
reaches neither logcat nor the unified log — the lines simply go nowhere.
Use `ConsoleSink.usingPrint()` (or `ConsoleSink(write: debugPrint)`) in a
Flutter app.

### Debug / profile / release

`ailog` exposes `isDebugBuild` / `isProfileBuild` / `isReleaseBuild` and
`byBuildMode(...)` without depending on Flutter — they read the same
`dart.vm.product` / `dart.vm.profile` constants `kReleaseMode` does:

```dart
final logger = Logger.create(
  sink: sink,
  minimumLevel: byBuildMode(debug: LogLevel.trace, release: LogLevel.info),
);
```

See [ailog's README](../ailog/README.md#debug--profile--release-builds) for
switching logging off entirely, what it costs, and why keeping it on in
release is usually the better call for a package built around post-mortem
analysis.

## Navigation breadcrumbs

```dart
MaterialApp(
  navigatorObservers: [AilogNavigatorObserver(logger)],
  // ...
)
```

Push/pop/remove/replace land in the JSONL as `info` events, so "which screens
did the user pass through before the crash" is answerable from the log alone.

## `AilogFlutter.install` options

| Option | Default | What it does |
|---|---|---|
| `recordFlutterErrors` | `true` | Hooks `FlutterError.onError` — framework and build errors |
| `recordPlatformDispatcherErrors` | `true` | Hooks `PlatformDispatcher.onError` — uncaught errors that escaped the zone, recorded as `fatal` |
| `captureWidgetBuildErrors` | `true` | Hooks `ErrorWidget.builder` — records what caused the red/grey screen, without changing what's displayed |

All of them **chain** rather than replace whatever handler was already
installed. `install` only takes effect on the first call per process, to
avoid double-logging from repeated registration.

## Logging from native code (iOS/Android)

`ailog_flutter` is a real Flutter plugin, so Kotlin and Swift code —
plugins, background work, existing native modules — can log into the same
JSONL file.

```dart
// Dart side: pass the same path your JsonlFileSink writes to.
final bridge = AilogNativeBridge.install(logger, logFilePath: logFile);
```

```kotlin
// Android (Kotlin) — anywhere in app/src
import dev.ailog.ailog_flutter.Ailog

Ailog.info("payment started", context = mapOf("orderId" to orderId))
Ailog.debug("cache warmed", tags = listOf("startup"))

try {
    chargeCard()
} catch (e: PaymentException) {
    Ailog.error(e, context = mapOf("orderId" to orderId))
}
```

```swift
// iOS (Swift) — anywhere in ios/Runner
import ailog_flutter

Ailog.info("payment started", context: ["orderId": orderId])
Ailog.debug("cache warmed", tags: ["startup"])

do {
    try chargeCard()
} catch {
    Ailog.error(error, context: ["orderId": orderId])
}
```

Working examples live in
[`example/android/…/MainActivity.kt`](example/android/app/src/main/kotlin/dev/ailog/ailog_flutter_example/MainActivity.kt)
and [`example/ios/Runner/AppDelegate.swift`](example/ios/Runner/AppDelegate.swift).

### How it works, and what it guarantees

**Normal path.** `Ailog.*` calls travel over the `dev.ailog/flutter`
MethodChannel into the Dart `Logger`, so they get exactly the same
treatment as Dart-originated events: redaction, sanitization, causal chain,
one shared file. If the Flutter engine hasn't attached yet (e.g. a call from
`Application.onCreate()` or `didFinishLaunchingWithOptions`), calls are
queued in memory — up to 50 — and flushed in order once it does.

**Crash path.** An uncaught native exception may unwind *after* the Flutter
engine is gone, with no channel left to send anything over. Only in that
case does the native side write the JSONL line directly to `logFilePath`,
bypassing Dart entirely. The handlers used for this
(`Thread.setDefaultUncaughtExceptionHandler` on Android,
`NSSetUncaughtExceptionHandler` on iOS) **always chain to whatever was
previously installed**, so Crashlytics/Sentry and normal crash behavior keep
working.

Lines written on the crash path carry their own `ses` (generated per
process) and `seq` — a separate writer, not a continuation of the Dart
session. `ailog_digest` still groups them correctly, because grouping keys
off the error fingerprint, not the session.

### Platform limitations — read before relying on this for crash reporting

- **Android**: `Thread.setDefaultUncaughtExceptionHandler` catches
  essentially all uncaught Java/Kotlin exceptions.
- **iOS**: `NSSetUncaughtExceptionHandler` only observes Objective-C
  `NSException`s. It does **not** catch Swift runtime traps (force-unwrapping
  `nil`, array out-of-bounds, `fatalError()`) or signal-based crashes
  (`SIGSEGV` and friends) — those abort the process directly. Catching those
  requires an async-signal-safe C signal handler, which this package
  deliberately does not implement. Treat the crash path as a best-effort
  supplement to a dedicated crash reporter, not a replacement.

### Fingerprint parity

The native `Ailog.error`/`fatal` compute error fingerprints from stack frame
strings using the **same algorithm as Dart** (FNV-1a 64). The same error type
with the same frames produces the same fingerprint whether it arrived over
the channel or was written by the crash handler — verified against the Dart
implementation with real reference values in
[`android/src/test/kotlin/…/AilogWireTest.kt`](android/src/test/kotlin/dev/ailog/ailog_flutter/AilogWireTest.kt).

> The Swift port mirrors the Kotlin one exactly, but this development
> environment has no Xcode/macOS toolchain, so it has been reviewed rather
> than build-verified. Confirm it compiles and behaves on a real device or
> simulator before shipping.

## Example app

[`example/`](example) is a runnable app (`flutter run`, with full `android/`
and `ios/` scaffolding). Five buttons fire the five automatic recording
paths: navigation, caught errors, widget build errors, uncaught async
errors, and native→Dart logging. See
[`example/README.md`](example/README.md).

## Notes

- `ailog_flutter` re-exports `ailog`, so a single import is enough.
- Redaction, sanitization, causal chain behavior and so on all follow the
  `ailog` configuration you pass in.
- Since v0.2.0 this is a Flutter plugin (it has `android/` and `ios/`
  directories). Projects that don't need native logging are unaffected —
  none of that code runs unless you call `AilogNativeBridge.install`.
