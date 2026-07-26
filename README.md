# ai-readable-logs

**Logs designed to be read by an AI, not scrolled by a human.**

> ### 🚧 Under active development — pre-1.0, not yet on pub.dev
>
> Everything documented here is implemented and tested (352 tests for
> `ailog`, 29 for `ailog_flutter`, run on every push), but the packages are
> **`0.x`** and the API is **not stable yet**. Expect breaking changes in
> minor versions until `1.0.0`; the [CHANGELOG](packages/ailog/CHANGELOG.md)
> lists them, and this one has already renamed and removed public API.
>
> **Reasonable to use now** for your own apps and internal tools — pin an
> exact version, read the changelog before upgrading. **Not yet reasonable**
> to depend on from a package other people install, since a breaking change
> here becomes a breaking change for them.
>
> Not yet done: the iOS Swift side has never been compiled by CI (no macOS
> runner), and neither package has been published, so `pub add ailog` does
> not work — use the git dependency shown below. Bug reports and API
> feedback are the most useful thing you can send right now.

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

Want a "send logs" share-sheet button? See
[ailog_flutter's README](packages/ailog_flutter/README.md#sharing-logs-with-a-send-logs-button)
for a ~30-line recipe built on
[log_vault](https://pub.dev/packages/log_vault) — small enough that it isn't
its own package.

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

  // Pushes any buffered lines to disk, then releases the sink. close() is
  // the one that matters for a script like this one: JsonlFileSink runs a
  // background timer to auto-flush, and only close() cancels it — call
  // flush() alone and this process never exits.
  await logger.flush();
  await logger.close();
}
```

### Bringing existing `print()` calls along

Everything above assumes you call `logger.info(...)`. Most codebases have a
lot of code that doesn't yet — and third-party packages that never will.
Those `print()` lines go to the console and nowhere else, so they are
missing from the file an AI reads.

`capturePrints` is not a different way to log. It **wraps whatever you were
already doing**, and additionally routes `print()` through the same logger.
Same setup as above, one line added:

```dart
Future<void> main() async {
  final logger = Logger.create(sink: /* …exactly as above… */);

  // Everything that runs inside here — your code, your dependencies, at any
  // depth — has its print() calls logged as well as printed.
  await capturePrints(logger, () async {
    print('a legacy debugging line');   // → console AND app.jsonl

    await runWithScope(logger.startTrace(context: {'requestId': 'req-1'}), () async {
      logger.info('checkout started');  // a normal log call, unchanged
      print('not migrated yet');        // captured, and carries req-1's trace
    });
  });

  await logger.close();
}
```

So the two styles coexist: `logger.info` gives you levels, structured
context and spans; `print` gives you the lines you haven't gotten to yet.
Both land in the same file, and captured prints are tagged `print` so you
can see how much is left to migrate.

Captured lines follow the same scope rule as any other event — they carry
whatever trace is active where the `print()` runs. Above, the first print
has none; the one inside `runWithScope` carries `req-1`.

## Getting an answer out of it

`.ailog/app.jsonl` is already usable as-is: paste it into a chat, attach it
to a bug report, or point an agent at the file. Every line stands alone, and
the first line of the file explains what each key means, so nothing external
is needed to interpret it.

For anything longer than a few hundred lines, summarize it first. This runs
locally — it reads the file and prints Markdown, nothing is uploaded:

```sh
dart run ailog:ailog_digest .ailog/app.jsonl
```

Copy that output into your AI chat. From 27 events it produces:

```text
# Log digest

- Events: 27
- Levels: info=21, error=6

## Top errors (by distinct failures)

### 1. `_Exception` (×3, fp:fedc5e26)

- Message: Exception: card declined
- Distinct failures: 3
- Log events: 6 (the same failure logged at multiple layers)
- Context (first of 3): requestId=req-4
- Context (most recent): requestId=req-12
- Top frames:
  - `main.dart:4 chargeCard`
  - `main.dart:14 main.<anonymous closure>.<anonymous closure>`
- Events leading up to it:
  - `-10ms` [info] checkout started requestId=req-4 userEmail=[redacted:email#42671e62]
  - `-3ms` [error] charge_card failed requestId=req-4

## Event mix (all 27 events)

- `app` [info] `checkout started` ×12
- `app` [info] `charge_card completed` ×9
- `app` [error] `charge_card failed` ×3
- `app` [error] `exception: card declined` ×3
```

Which is enough for a model to answer *what broke, how often, and what led
to it* without reading the file at all:

- **What** — `_Exception: card declined`, thrown at `main.dart:4 chargeCard`.
- **How often** — 3 distinct failures, not 6. The same failure was logged at
  two layers (the span, then the caller's `catch`); counting log lines would
  have reported the bug as twice as frequent as it is.
- **Out of how many** — 12 checkouts started, 9 charges completed. The
  missing 3 are the failures. A count that *should* balance and doesn't is
  often the whole diagnosis.
- **What led to it** — the two events immediately preceding, with their
  context, embedded in the error itself.
- **Whether it's one bug or several** — `fp:fedc5e26` is a fingerprint over
  the normalized stack; identical fingerprints are the same bug even when
  the messages differ.

Note `userEmail=[redacted:email#42671e62]` — the address never reached the
file, but the same user still produces the same token, so "these lines are
one person" survives redaction.

Use `--format json -o digest.json` instead when a program, not a person, is
consuming it. If the file is large enough that even the digest feels
lossy, [`LogFilter`](packages/ailog/README.md#sending-logs-to-an-ai-without-sending-junk)
trims the raw events while keeping the whole-log counts intact.

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
