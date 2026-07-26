# ailog_flutter

Connects [`ailog`](https://github.com/FuruyamaMasayuki/ai-readable-logs/blob/main/packages/ailog) to a Flutter app. Automatically records the
framework's error channels (`FlutterError.onError`,
`PlatformDispatcher.onError`, `ErrorWidget.builder`) and navigation into the
same AI-readable JSONL output — and bridges native Kotlin/Swift code into it
too.

> ### 🚧 Under active development — `0.x`, API not stable
>
> Implemented and covered by 29 widget/unit tests on top of `ailog`'s 352,
> but **breaking changes land in minor versions until `1.0.0`** — read the
> [CHANGELOG](https://github.com/FuruyamaMasayuki/ai-readable-logs/blob/main/packages/ailog_flutter/CHANGELOG.md) before upgrading, and pin an exact version.
>
> One gap worth knowing about before you rely on it: **neither native side
> is built by CI**, because the workflow has no macOS runner and does not run
> a Gradle build. The Dart half of the bridge is fully tested, and
> `android/src/main/kotlin/.../AilogWire.kt` — the fingerprinting and
> JSONL-writing core — compiles standalone and has a JUnit test
> (`AilogWireTest.kt`) covering hash parity with the Dart implementation.
> The Swift files have never been through a compiler at all. If you hit an
> iOS build error, that is why; please file it.

## Install

The packages are **not on pub.dev yet**, so `flutter pub add ailog_flutter`
will not find them. Depend on them from the repository:

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
      LevelFilterSink(ConsoleSink.usingPrint(), LogLevel.info),
    ]),
    // Debug and profile only. A `flutter build` release is silent unless you
    // add `enabled: true` — see "Debug / profile / release" below.
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
reaches the log file otherwise. Captured lines are tagged `print` and follow
the same scope rule as every other log call — they carry whatever trace is
active where the `print()` runs, and none if there isn't one. Set
`forwardPrintsToConsole: false` if you attach a `ConsoleSink`, or each line
appears twice.

This works by installing a `Zone`, so it applies to a `print()` anywhere
inside `runAppGuarded`'s callback — including one made deep inside a
dependency — with no per-package setup. It does **not** reach a
`compute()` call or anything run via `Isolate.spawn`/`Isolate.run`: those
start a fresh isolate with its own zone tree, so prints made there need
their own `capturePrints` call inside that isolate. See
[ailog's README](https://github.com/FuruyamaMasayuki/ai-readable-logs/blob/main/packages/ailog/README.md#how-it-actually-works) for the
mechanism in full, including what is and isn't captured.

### Console output on a device

`ConsoleSink` writes to `stdout` by default, which on a Flutter device
reaches neither logcat nor the unified log — the lines simply go nowhere.
Use `ConsoleSink.usingPrint()` (or `ConsoleSink(write: debugPrint)`) in a
Flutter app.

### Debug / profile / release

> **A `flutter build` release ships with logging off.** `enabled` defaults
> to `!isReleaseBuild`, so nothing is written to a user's device unless you
> ask for it. Debug and profile builds are unaffected.
>
> If you want production logs — and you do, if you have any way to get the
> file back — opt in explicitly:
>
> ```dart
> Logger.create(sink: sink, enabled: true, minimumLevel: LogLevel.info);
> ```

`ailog` exposes `isDebugBuild` / `isProfileBuild` / `isReleaseBuild` and
`byBuildMode(...)` without depending on Flutter — they read the same
`dart.vm.product` / `dart.vm.profile` constants `kReleaseMode` does:

```dart
final logger = Logger.create(
  sink: sink,
  enabled: true, // ← without this, release never consults minimumLevel
  minimumLevel: byBuildMode(debug: LogLevel.trace, release: LogLevel.info),
);
```

Two things worth deciding before you ship, both easy to overlook:

- **How big the file may get.** `JsonlFileSink(maxBytes:, maxFiles:)`
  bounds it — the default is 8 MiB × 5 files, so up to 40 MiB of app
  storage. Lower it for a phone.
- **Whether the log is ever retrieved.** A release build that logs to a
  device nobody collects from is pure cost. Wire up
  [sharing](#sharing-logs-with-a-send-logs-button) and opt in with
  `enabled: true`, or leave the release default alone and accept the blind
  spot deliberately.

See [ailog's README](https://github.com/FuruyamaMasayuki/ai-readable-logs/blob/main/packages/ailog/README.md#debug--profile--release-builds) for
the `const` form that compiles the sink out entirely, what a call on a
disabled logger actually costs, and why opting back in is usually the better
call for a package built around post-mortem analysis.

## Navigation breadcrumbs

```dart
MaterialApp(
  navigatorObservers: [AilogNavigatorObserver(logger)],
  // ...
)
```

Push/pop/remove/replace land in the JSONL as `info` events, so "which screens
did the user pass through before the crash" is answerable from the log alone.

## User interaction logging

"What was the person doing just before this broke" is the most valuable
thing a bug report can carry, and `ailog` already has the mechanism: at the
default `trace` level these stay **out of the file** but are retained as
breadcrumbs, so they surface embedded in the causal chain of whatever fails
next.

### App lifecycle

```dart
final lifecycle = AilogLifecycleObserver(logger)..install();
```

Foreground/background/termination, with both ends of each transition
(`paused → resumed`). A handful of events over a whole session, and
repeatedly decisive: "crashes when you come back to the app" is invisible in
a log that only records what the code did.

### Taps and other actions

```dart
ElevatedButton(
  onPressed: () {
    logger.interaction('checkout_pressed', context: {'items': cart.length});
    _checkout();
  },
  child: const Text('Pay now'),
)
```

Log the **intent**, not the caption. `checkout_pressed` survives copy
changes, translation and A/B tests and groups across all of them; `"Pay now"`
/ `"支払う"` splits one behaviour into as many buckets as you have locales.

In practice you write this once, in a shared button component, and every
screen gets it:

```dart
class AppButton extends StatelessWidget {
  const AppButton({super.key, required this.action, required this.onPressed, required this.child});
  final String action;
  final VoidCallback onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) => ElevatedButton(
        onPressed: () {
          logger.interaction(action);
          onPressed();
        },
        child: child,
      );
}
```

What lands in the log when something then fails:

```text
ERROR checkout failed [fp:7ed4a8d1]
  — causal chain (4 events) —
    -11ms  ▸ view_cart_pressed
    -10ms  route pushed: /cart
    -8ms   ▸ coupon_applied
    -6ms   ▸ checkout_pressed
```

### Why there is no automatic "log every tap"

A single root-level `Listener` catching every pointer event is the obvious
idea, and this package deliberately does not ship one. Measured against a
real widget tree, what a root `Listener` plus a hit test can actually
recover is:

| Tapped | Recovered |
|---|---|
| `ElevatedButton` with a `Text` child | `"Add to cart"` — useful |
| `IconButton` (even with a `tooltip`) | "a button", no label |
| `TextField`, most other widgets | nothing |

So the automatic route yields raw coordinates for most of the screen —
`tap at (234, 567)` tells an AI nothing — plus a label for text buttons
only. Against that it costs a hit test on every pointer-down (one scroll is
many), volume in a format whose entire premise is not wasting a context
window, and a real privacy problem: **semantic labels contain user data**.
A contacts row is labelled with a person's name; a message row with the
message. Regex redaction cannot catch that.

Explicit `interaction()` calls cost one line each and give strictly better
data. If you still want the automatic version for a debug build, it is about
fifteen lines — wrap your app in a `Listener`, hit-test `event.position`, and
pull `SemanticsConfiguration.label` off the path — and you can decide for
yourself what to do about the caveats above.

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
[`example/android/…/MainActivity.kt`](https://github.com/FuruyamaMasayuki/ai-readable-logs/blob/main/packages/ailog_flutter/example/android/app/src/main/kotlin/dev/ailog/ailog_flutter_example/MainActivity.kt)
and [`example/ios/Runner/AppDelegate.swift`](https://github.com/FuruyamaMasayuki/ai-readable-logs/blob/main/packages/ailog_flutter/example/ios/Runner/AppDelegate.swift).

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
[`android/src/test/kotlin/…/AilogWireTest.kt`](https://github.com/FuruyamaMasayuki/ai-readable-logs/blob/main/packages/ailog_flutter/android/src/test/kotlin/dev/ailog/ailog_flutter/AilogWireTest.kt).

> The Swift port mirrors the Kotlin one exactly, but this development
> environment has no Xcode/macOS toolchain, so it has been reviewed rather
> than build-verified. Confirm it compiles and behaves on a real device or
> simulator before shipping.

## Getting the log off a real device

`dart run ailog:ailog_digest .ailog/app.jsonl` runs on **your development
machine** and needs a path it can read. On a real device, `app.jsonl` lives
inside the app's private storage — there is no shell on your laptop that can
just open that path. Four ways to actually get at it, in order of how much
tooling they need:

1. **No tooling at all: read it from inside the app.** Keep a `MemorySink`
   alongside the file sink, and put its output in a debug screen or behind
   a hidden gesture:
   ```dart
   final recent = MemorySink(capacity: 2000);
   final logger = Logger.create(sink: MultiSink([fileSink, recent]));
   // ...
   Text(recent.toMarkdown());                    // or toJsonl()
   Clipboard.setData(ClipboardData(text: recent.toMarkdown()));
   ```
   Works identically on a real device, a simulator, or the web. Nothing ever
   leaves the app until you decide to copy it somewhere.

2. **Stream it live, while you're already debugging.** `flutter run`
   mirrors the app's `print` output into your terminal in real time — the
   same channel `debugPrint` uses — over USB, with no manual pull step at
   all. Add [`JsonlPrintSink`](https://github.com/FuruyamaMasayuki/ai-readable-logs/blob/main/packages/ailog/README.md#capturing-a-debug-session-as-a-file)
   to the sink list and capture the session:
   ```dart
   Logger.create(sink: MultiSink([fileSink, JsonlPrintSink(write: debugPrint)]))
   ```
   ```sh
   flutter run | tee session.log
   # later, or in another terminal:
   grep -oE '\{.*\}' session.log > app.jsonl
   dart run ailog:ailog_digest app.jsonl
   ```
   `grep -oE` pulls just the `{...}` JSON out of each line rather than
   assuming it starts at column 1, because on Android this channel is
   usually routed through logcat, which prepends its own
   `I/flutter ( 1234):` tag. Pass `write: debugPrint`, not bare `print` —
   plain `print` calls faster than Android's log rate limit can be silently
   dropped, which is exactly the problem `debugPrint` exists to avoid.

3. **Send it off the device: the share sheet.** See
   ["Sharing logs with a 'send logs' button"](#sharing-logs-with-a-send-logs-button)
   below — AirDrop, Slack, email, Files, whatever the platform offers. Once
   you (or a tester) sends it to you, it's an ordinary file on your machine
   and `ailog_digest` works exactly as documented above.

4. **Pull it with device tooling**, if you have the device connected. The
   exact path is whatever you passed to `JsonlFileSink(path: ...)` — usually
   somewhere under `getApplicationSupportDirectory()` or
   `getApplicationDocumentsDirectory()` (`sink.path` on the `JsonlFileSink`
   itself always has the true answer):
   - **Android:** `adb pull` the path (debug builds; on a release build
     without `run-as` access, `adb pull` a directory you can't reach
     directly may not work — fall back to another option above).
   - **iOS:** Xcode → Window → Devices and Simulators → select the device →
     your app → the gear icon → **Download Container...**, then find the
     file inside the extracted `.xcappdata` bundle.

For anyone who isn't the developer holding a debugger — a QA tester, a
support ticket, a beta user — option 3 is the only one that doesn't require
them to have Xcode or `adb` installed, which is why it's worth wiring up
even for an internal build.

## Sharing logs with a "send logs" button

[`log_vault`](https://pub.dev/packages/log_vault) is a separate package (by
the same author) that owns the "zip and open the platform share sheet" flow
— worth reusing rather than reimplementing. This isn't a separate `ailog`
package; it's about 30 lines you copy in, because that's genuinely all it
is: two small functions gluing two libraries together, not enough to justify
its own pubspec/CHANGELOG/CI job. (An earlier revision shipped this as
`ailog_vault`; it added three moving parts for what turned out to be small
enough to just paste.)

```yaml
# pubspec.yaml
dependencies:
  log_vault: ^0.1.0
```

```dart
// lib/log_share.dart
//
// Regenerates a digest from ailog's JSONL files and hands both to
// log_vault's share sheet. Copy this in and adjust paths/names as needed.
import 'dart:convert';
import 'dart:io';

import 'package:ailog/ailog.dart';
import 'package:flutter/widgets.dart';
import 'package:log_vault/log_vault.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

final RegExp _jsonlPattern = RegExp(r'\.jsonl(\.\d+)?$');

/// Reads every `.jsonl` file in [ailogDir] (oldest rotation first), builds
/// a digest, and writes it to `digest.md` beside them. Call this right
/// before sharing so it always describes the current files — it is
/// typically the only thing whoever receives the zip needs to open.
Future<Digest> writeAilogDigest(Directory ailogDir) async {
  final builder = DigestBuilder();
  if (await ailogDir.exists()) {
    final files = await ailogDir
        .list()
        .where((e) => e is File && _jsonlPattern.hasMatch(p.basename(e.path)))
        .cast<File>()
        .toList();
    files.sort((a, b) => _rotationRank(b.path) - _rotationRank(a.path));
    for (final file in files) {
      for (final line in const LineSplitter().convert(await file.readAsString())) {
        builder.addLine(line);
      }
    }
  }
  final digest = builder.build();
  await File(p.join(ailogDir.path, 'digest.md'))
      .writeAsString(digest.toMarkdown());
  return digest;
}

/// `app.jsonl` → 0, `app.jsonl.3` → 3. Sorting oldest-first by this (not by
/// the path string) matters once there are 10+ rotations — ".10" sorts
/// before ".2" as a string, but not as a number.
int _rotationRank(String path) {
  final match = RegExp(r'\.jsonl\.(\d+)$').firstMatch(path);
  return match == null ? 0 : int.parse(match.group(1)!);
}

/// Regenerates the digest, then shares log_vault's own zip (its
/// `log_YYYYMMDD.log` files) together with ailog's JSONL and the digest as
/// extra attachments in the same share sheet.
Future<void> shareLogs(
  BuildContext context, {
  required LogDumper dumper,
  required Directory ailogDir,
  String subject = 'App logs',
}) async {
  await writeAilogDigest(ailogDir);
  final jsonlFiles = await ailogDir
      .list()
      .where((e) => e is File && _jsonlPattern.hasMatch(p.basename(e.path)))
      .cast<File>()
      .toList();

  await ShareLogDumper(dumper).share(
    context,
    subject: subject,
    extraFiles: [
      ...jsonlFiles.map((f) => XFile(f.path)),
      XFile(p.join(ailogDir.path, 'digest.md')),
    ],
  );
}
```

```dart
// Wiring it up: one LogDumper, reused across calls (it deletes the
// previous zip before building the next one — see log_vault's docs).
final dumper = LogDumper(
  directory: Directory('${(await getApplicationSupportDirectory()).path}/logs'),
  appName: 'my_app',
);

// In a "send logs" button:
onPressed: () => shareLogs(
  context,
  dumper: dumper,
  ailogDir: Directory('${(await getApplicationSupportDirectory()).path}/ailog'),
),
```

Attachments this way ride alongside log_vault's zip rather than inside it —
the share sheet shows both, which is a fine outcome and needs nothing beyond
what's on pub.dev today. If you'd rather have one zip containing everything,
`LogDumper` would need an `extraPatterns`-style hook to pick up `.jsonl`
files from its own directory; that isn't in the published log_vault yet.

## Example app

[`example/`](https://github.com/FuruyamaMasayuki/ai-readable-logs/blob/main/packages/ailog_flutter/example) is a runnable app (`flutter run`, with full `android/`
and `ios/` scaffolding). Five buttons fire the five automatic recording
paths: navigation, caught errors, widget build errors, uncaught async
errors, and native→Dart logging. See
[`example/README.md`](https://github.com/FuruyamaMasayuki/ai-readable-logs/blob/main/packages/ailog_flutter/example/README.md).

## Notes

- `ailog_flutter` re-exports `ailog`, so a single import is enough.
- Redaction, sanitization, causal chain behavior and so on all follow the
  `ailog` configuration you pass in.
- Since v0.2.0 this is a Flutter plugin (it has `android/` and `ios/`
  directories). Projects that don't need native logging are unaffected —
  none of that code runs unless you call `AilogNativeBridge.install`.
