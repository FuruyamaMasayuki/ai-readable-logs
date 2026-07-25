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

## Packages

| Package | What it's for |
|---|---|
| [`packages/ailog`](packages/ailog) | The core. Zero dependencies, pure Dart — usable from CLIs, servers, and Flutter alike |
| [`packages/ailog_flutter`](packages/ailog_flutter) | Flutter add-on: automatic `FlutterError`/`PlatformDispatcher`/`ErrorWidget` hooks, navigation breadcrumbs, and a **native (Kotlin/Swift) → Dart logging bridge** |

## Quick start

```dart
import 'package:ailog/ailog.dart';

Future<void> main() async {
  final logger = Logger.create(
    sink: MultiSink([
      JsonlFileSink(path: '.ailog/app.jsonl'),          // for the AI
      LevelFilterSink(ConsoleSink(), LogLevel.info),    // for you
    ]),
  );

  final scope = logger.startTrace(context: {'requestId': 'req-1'});
  await runWithScope(scope, () async {
    logger.info('checkout started', context: {'userEmail': 'a@example.com'});

    await logger.span('charge_card', (span) async {
      await chargeCard();   // throws → error, duration and causal chain logged
    });
  });

  await logger.flush();
}
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
