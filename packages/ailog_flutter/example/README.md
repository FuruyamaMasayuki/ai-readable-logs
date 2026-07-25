# ailog_flutter example

A runnable app demonstrating every automatic recording path in
`ailog_flutter`, with full `android/` and `ios/` scaffolding.

```sh
cd example
flutter pub get
flutter run
```

`JsonlFileSink` needs a filesystem, so this example is native-only
(Android/iOS/desktop) — it does not run on the web. See
[the core package's limitations](../../ailog/README.md#limitations).

On launch it writes to `$TMPDIR/ailog_example/app.jsonl`; the path is printed
to the console too.

## What the buttons do

| # | Button | Path exercised |
|---|---|---|
| 1 | Navigate | `AilogNavigatorObserver` records push/pop as `info` events |
| 2 | Caught error | A plain `logger.error()` call |
| 3 | Widget build error | The `ErrorWidget.builder` hook records the cause of the red/grey screen (without changing what's shown) |
| 4 | Uncaught async error | The `PlatformDispatcher.onError` hook records it as `fatal` |
| 5 | Log from native | `AilogNativeBridge.requestNativeTestLog()` triggers `Ailog.info()` on the Kotlin/Swift side, which arrives back over the MethodChannel |

## Native logging

The example also logs from native lifecycle callbacks, so you can see
native and Dart events interleaved in one file:

- [`android/app/src/main/kotlin/dev/ailog/ailog_flutter_example/MainActivity.kt`](android/app/src/main/kotlin/dev/ailog/ailog_flutter_example/MainActivity.kt)
- [`ios/Runner/AppDelegate.swift`](ios/Runner/AppDelegate.swift)

Both include a call made *before* the Flutter engine attaches, to show the
queue-and-flush behavior, and a caught error to show fingerprinted native
errors crossing the bridge.

## Reading the result

```sh
dart run ../../ailog/bin/ailog_digest.dart "$TMPDIR/ailog_example/app.jsonl"
```
