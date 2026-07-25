# ai-readable-logs

**Logs designed to be read by an AI, not scrolled by a human.**

Structured logging for Dart and Flutter. One JSON object per line (JSONL),
where **every line carries enough context to diagnose on its own** — the
events that led up to it, where the failure came from, and a stable
fingerprint that groups it with other occurrences of the same bug.

```jsonc
{
  "ts": "2026-07-25T10:09:32.405471Z",
  "lvl": "error",
  "msg": "Exception: card declined",
  "tr": "2efd38d3...",
  "err": { "t": "_Exception", "fp": "56161699",
           "fr": ["checkout.dart:42 CartService.charge"] },
  "chain": [                                   // ← what happened just before
    { "dt": -24, "lvl": "info", "msg": "checkout started",
      "ctx": { "userEmail": "[redacted:email#892c8bf7]" } }
  ]
}
```

## Why "AI-readable"?

Hand a normal log file to an AI and most of the cost goes into one thing:
reading the *whole file* just to find what happened before the error. This
package removes that step structurally.

| | What it does | Why an AI cares |
|---|---|---|
| **Causal chain** | Each error line embeds the preceding events from the same trace | The model reads one line instead of scanning backwards through the file |
| **Error fingerprints** | Stack traces are normalized and hashed | "Same bug" groups together despite shifting line numbers and varying IDs in the message |
| **Self-describing files** | A legend line describing every key is written at the top of each file | No external schema doc needed — the file explains itself |
| **Digest CLI** | `ailog_digest` reduces hundreds of thousands of lines to a ranked summary | Fits in a context window |
| **Automatic redaction** | Emails, tokens, card numbers masked as `[redacted:kind#hash]` | Safe to paste into a chat; equal hashes still reveal "same user across these lines" |
| **Checkpoints** | `logger.checkpoint()` logs *where* it was called, with no message | Proves a code path ran without polluting logs with `"here"` strings |
| **Whole-log aggregates** | Every message shape counted, every numeric context field's range | `40 lease acquired` against `9 lease released` is a diagnosis one summary line long |
| **Filtered string output** | `LogFilter` + `toReport()` return text, never a file | Send the relevant slice to a model instead of 40,000 healthy lines |

### This is measured, not asserted

The digest was tested by handing the same connection-pool leak to two blind
diagnosis runs — one with the raw log, one with the digest — and comparing.
The raw log won the first round outright, because summarising had destroyed
the evidence: the proof of a leak is the releases that *never happen*, spread
across the requests that succeeded. Adding whole-log counts closed the gap;
the digest then found the same root cause, naming the branch at fault, from
1.7 KB instead of 9.5 KB. Details in
[`packages/ailog/README.md`](packages/ailog/README.md#aggregates-what-a-summary-usually-destroys).

## Packages

| Package | What it's for |
|---|---|
| [`packages/ailog`](packages/ailog) | The core. Zero dependencies, pure Dart — usable from CLIs, servers, and Flutter alike |
| [`packages/ailog_flutter`](packages/ailog_flutter) | Flutter add-on: automatic `FlutterError`/`PlatformDispatcher`/`ErrorWidget` hooks, navigation breadcrumbs, and a **native (Kotlin/Swift) → Dart logging bridge** |
| [`packages/ailog_vault`](packages/ailog_vault) | Share the logs: zips the JSONL + a fresh digest and opens the platform share sheet, via [log_vault](https://pub.dev/packages/log_vault) |

## Quick start

```dart
import 'package:ailog/ailog.dart';

Future<void> main() async {
  // One logger per process. MultiSink fans each event out to every sink in
  // the list — nothing here is exclusive to one destination.
  final logger = Logger.create(
    sink: MultiSink([
      JsonlFileSink(path: '.ailog/app.jsonl'),          // the file an AI reads
      LevelFilterSink(ConsoleSink(), LogLevel.info),    // what you watch live;
      // LevelFilterSink keeps the terminal to info-and-up without making the
      // file lossy — the two sinks don't have to agree on what to keep.
    ]),
  );

  // A trace = one logical operation (here: handling one checkout). Anything
  // logged inside runWithScope's callback — including after an `await`, or
  // from a callback fired later — automatically carries this trace's id and
  // any context passed to startTrace. No id parameter to thread by hand.
  final scope = logger.startTrace(context: {'requestId': 'req-1'});
  await runWithScope(scope, () async {
    // A normal log call: level, message, and free-form structured context.
    // The email is masked automatically before it ever reaches the sink —
    // see "Redaction" below.
    logger.info('checkout started', context: {'userEmail': 'a@example.com'});

    // A span times one step and auto-closes on return or throw. On success
    // its duration is recorded; on failure the thrown error, its duration,
    // and the causal chain (the events that happened just before it, in this
    // same trace — including the 'checkout started' line above) are all
    // attached to the error line, and the exception still propagates
    // normally to whatever catches it outside this block.
    await logger.span('charge_card', (span) async {
      await chargeCard();   // throws → error, duration and causal chain logged
    });
  });

  // Pushes any buffered lines to disk. Call this before reading the file
  // back, before the process exits, or before sharing/uploading it.
  await logger.flush();
}
```

Plain `print()` calls are captured too, so code you haven't migrated (or a
third-party package's own prints) still ends up in the file:

```dart
capturePrints(logger, () {
  print('a legacy debugging line');   // → console AND app.jsonl, with the trace attached
  runApplication();
});
```

Then hand the result to an AI:

```sh
dart run ailog:ailog_digest .ailog/app.jsonl          # ranked Markdown summary
dart run ailog:ailog_digest .ailog/app.jsonl --format json -o digest.json
```

## Logging from native iOS/Android code

`ailog_flutter` is a real Flutter plugin, so Kotlin and Swift code can log
into the *same* JSONL file:

```kotlin
// Android
Ailog.info("payment started", context = mapOf("orderId" to orderId))
```

```swift
// iOS
Ailog.info("payment started", context: ["orderId": orderId])
```

These normally forward over a MethodChannel into the Dart logger. When an
uncaught native exception fires — possibly after the Flutter engine is
already gone — the native side falls back to writing the JSONL line
directly, using a byte-identical port of the same fingerprint algorithm, so
crashes still group correctly. See
[`packages/ailog_flutter`](packages/ailog_flutter#logging-from-native-code-iosandroid)
for the full contract and its platform limitations.

## Documentation

- [`packages/ailog/README.md`](packages/ailog/README.md) — core API, output
  format, redaction, digest CLI
- [`packages/ailog_flutter/README.md`](packages/ailog_flutter/README.md) —
  Flutter hooks and the native bridge
- [`packages/ailog/example/`](packages/ailog/example) and
  [`packages/ailog_flutter/example/`](packages/ailog_flutter/example) —
  runnable examples

## License

MIT — see [LICENSE](LICENSE).
