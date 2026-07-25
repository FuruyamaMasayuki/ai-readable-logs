# ailog

A zero-dependency, pure Dart structured logger designed to be read by an AI.

Logs a human scrolls through in a terminal and logs an AI diagnoses from want
different shapes. `ailog` commits fully to the second: one JSON object per
line (JSONL), where **each line carries what's needed to diagnose it on its
own**.

## Why

Hand a normal log file to an AI and most of the cost goes into one thing:
reading the whole file just to reconstruct what happened before an error.
`ailog` removes that step:

- **Causal chain** — each error line embeds the events that preceded it in
  the same trace. One line, whole story.
- **Trace / span correlation** — IDs issued by `startTrace` / `span`
  propagate automatically through `Zone`, including across `await` gaps. No
  threading a request ID through fifteen function signatures.
- **Error fingerprinting** — stack traces are normalized (line numbers and
  varying values stripped) and hashed, so the same bug groups together
  across occurrences.
- **Checkpoints** — `logger.checkpoint()` records *where it was called*
  (`→ checkout.dart:42 CartService.charge`) with no message to write.
- **Automatic redaction** — emails, tokens, card numbers and friends are
  detected and replaced with `[redacted:kind#hash]`. The hash is stable
  within a file, so "the same user appears in these five lines" survives
  even though the value doesn't.
- **Digest CLI** — `ailog_digest` compresses hundreds of thousands of lines
  into a frequency-ranked Markdown/JSON summary that fits in a context
  window.

## Install

```yaml
dependencies:
  ailog:
    path: ../ailog   # or a version constraint once published
```

## Usage

```dart
import 'package:ailog/ailog.dart';

Future<void> main() async {
  final logger = Logger.create(
    sink: MultiSink([
      JsonlFileSink(path: '.ailog/app.jsonl'),
      LevelFilterSink(ConsoleSink(), LogLevel.info),  // human-readable in dev
    ]),
  );

  final scope = logger.startTrace(context: {'requestId': 'req-1'});
  await runWithScope(scope, () async {
    logger.info('checkout started', context: {'userEmail': 'a@example.com'});

    await logger.span('charge_card', (span) async {
      // On failure: the error, its duration and the causal chain are all
      // recorded automatically, and the exception still propagates.
      await chargeCard();
    });
  });

  await logger.flush();
}
```

One emitted line, formatted for readability:

```jsonc
{
  "ts": "2026-07-25T10:09:32.405471Z",
  "lvl": "error",
  "msg": "Exception: card declined",
  "lg": "app",
  "tr": "2efd38d3...",           // trace: one logical operation
  "sp": "...",                   // span within the trace
  "ctx": { "requestId": "req-1" },
  "err": {
    "t": "_Exception",
    "m": "Exception: card declined",
    "fp": "56161699",            // fingerprint: the grouping key
    "fr": ["checkout.dart:42 CartService.charge", "..."]
  },
  "chain": [                     // what happened just before, same trace
    { "dt": -24, "lvl": "info", "msg": "checkout started",
      "ctx": { "userEmail": "[redacted:email#892c8bf7]" } }
  ]
}
```

Every file starts with an `_hdr` record documenting what each key means, so
an AI can interpret the format with no external documentation.

## Checkpoints — logging *where*, not *what*

Sometimes you want to know a code path executed, and writing a message for it
is busywork that ends up as noise (`'here'`, `'step 2'`, `'in handler'`).
`checkpoint()` records the call site instead:

```dart
Future<void> charge() async {
  logger.checkpoint();                    // → checkout.dart:12 CartService.charge
  await gateway.send();
  logger.checkpoint();                    // → checkout.dart:14 CartService.charge
}
```

Emitted lines are tagged `checkpoint` and prefixed with `→`, so they're
trivially greppable and an AI can tell them apart from deliberate messages.
They stay correct when the code moves, unlike hand-written markers.

Checkpoints default to `LogLevel.trace`, so a production `minimumLevel` of
`debug` or higher filters them out — and they cost nothing there, because the
stack is only captured *after* the level check passes.

`logger.info(null)` is the same thing at a different level. (Dart doesn't
allow optional positional and named parameters in one signature, so
`logger.info()` with no arguments at all can't coexist with the `context:` /
`tags:` named parameters — hence the explicit `null`.)

## Capturing plain `print()` calls

Nobody instruments a codebase all at once. `capturePrints` routes ordinary
`print()` — yours, or a third-party package's — into the structured log,
tagged `print`, carrying the ambient trace like any other event:

```dart
void main() {
  final logger = Logger.create(sink: JsonlFileSink(path: '.ailog/app.jsonl'));
  capturePrints(logger, () {
    print('legacy debugging line');   // → console AND app.jsonl
    runApplication();
  });
}
```

Set `forwardToConsole: false` if a `ConsoleSink` is attached, or each print
shows up twice (once raw, once formatted). Prints emitted by the logging
pipeline itself are passed through untouched — a console sink cannot feed
back into the log. In Flutter, `runAppGuarded(..., capturePrint: true)` does
the same thing with one flag.

## Per-subsystem loggers

```dart
final dbLogger = logger.child('db');
final httpLogger = logger.child('http');
```

Every logger derived with `child` shares one session ID, one sequence
counter and one causal buffer, so ordering and correlation hold even when a
single trace crosses several subsystems.

## AI digest

```sh
dart run ailog:ailog_digest .ailog/app.jsonl
```

Ranks errors and prints, per group, the representative frames and the causal
chain. Output size is bounded with `--max-groups`.

### Distinct failures vs. log events

Ranking is by **distinct failures**, not raw log lines — those differ more
often than you'd expect, and conflating them misleads:

```dart
await logger.span('charge', (s) => gateway.charge());  // logs the failure
// ...caller catches the same exception at the boundary
catch (e, st) { logger.error(e, st); }                 // logs it again
```

Both calls are correct in isolation. Together, one failed request produces
two error lines. Counting raw lines would report the bug as twice as
frequent as it is, and rank a deep-stack error above a shallower but
genuinely more widespread one.

The digest groups by trace instead, so one request that failed once counts
once, and reports both numbers when they diverge:

```text
### 1. `StateError` (×2, fp:386b7f5a)
- Distinct failures: 2
- Log events: 4 (the same failure logged at multiple layers)
```

Untraced events can't be attributed to a request, so each counts as its own
failure — an over-count, and a reason to wrap work in a trace.

```sh
dart run ailog:ailog_digest .ailog/app.jsonl --format json --max-groups 10 -o digest.json
```

`DigestBuilder` is also exported, so you can build the same summary in-process
(for an admin screen, a Slack notification, and so on) without shelling out:

```dart
final builder = DigestBuilder();
for (final line in File(path).readAsLinesSync()) {
  builder.addLine(line);
}
print(builder.build().toMarkdown(maxGroups: 5));
```

### Aggregates: what a summary usually destroys

The digest also counts **every message shape** and the **range of every
numeric context field** across the whole log:

```text
## Event mix (all 148 events)

- `http` [info] `get <path>` ×40
- `pool` [debug] `lease acquired` ×40
- `http` [info] `<n> ok` ×28
- `cache` [info] `cache hit` ×19
- `http` [error] `request failed` ×12
- `pool` [debug] `lease released` ×9

## Numeric context fields

- `leased`: min=0 max=31 last=31 (n=49)
- `max`: min=20 max=20 last=20 (n=40)
```

These two sections cost one line per distinct shape and repeatedly turn out
to *be* the diagnosis. Above: 40 acquires against 9 releases, and a counter
that ends at 31 against a limit of 20 — a connection-pool lease that is never
returned on the cache-hit path.

This exists because of a measured failure. The same bug was handed to two
blind diagnosis runs, one given the raw 160-line log and one given the
digest. The raw log won: root cause identified with high confidence, while
the digest run concluded *"I cannot tell a leak from an ordering bug."* The
proof of a leak is an **absence** — releases that never happen — spread
across the requests that *succeeded*, and nothing about a successful request
looks worth keeping. With the counts added, the digest reached the same root
cause, naming the specific branch at fault, from 1.7 KB instead of 9.5 KB.

The lesson generalises: summarisation destroys negative evidence, and
counting restores it cheaply.

## Sending logs to an AI without sending junk

`LogFilter` selects what is worth the context window; everything it produces
is a `String`.

```dart
final buffer = MemorySink(capacity: 2000);
final logger = Logger.create(sink: MultiSink([fileSink, buffer]));

// Digest + the events that survived filtering, as Markdown.
final report = buffer.export(LogFilter.forAi).toReport();
```

| Filter | Effect |
| --- | --- |
| `collapseRepeats` | Folds consecutive identical lines into one with `repeated: N`. A poll loop or a rebuilding widget stops being most of the file. |
| `aroundErrors: n` | Keeps only events within `n` of a failure — including ones from *other* traces, which is usually where the cause is. |
| `minimumLevel`, `loggers`, `since`, `maxEvents` | The obvious ones. |
| `onlyFailedTraces` | Keeps only traces that produced an error. Aggressive, and the one most likely to delete the answer — see above. |

`LogFilter.forAi` is `collapseRepeats` + `aroundErrors: 30`.

Two things are deliberate. **Aggregates are computed over the unfiltered
input**, so the acquire/release counts stay true even after the successful
requests are gone. And **the output says what was removed**, in both formats,
so a filtered log never reads as a complete one:

```text
_Filtered: 73 of 80 events were removed before listing (farFromError=73).
The counts above cover all 80._
```

## Getting the log as a string

No file required — this works identically on web.

```dart
buffer.toJsonl();                       // same wire format as the file sink
buffer.toMarkdown();                    // digest only
buffer.export(LogFilter.forAi).toReport();  // digest + surviving events

digestFromJsonl(text);                  // parse a log you already have
buildDigest(events);                    // aggregate in-memory events
```

`toJsonl()` emits the schema legend as its first line, so the string is
self-describing to a recipient that has never seen the format.

## Redaction

Enabled by default: emails, JWTs, bearer tokens, basic-auth URLs,
AWS/GCP/GitHub/Slack/Stripe keys, Luhn-validated card numbers, private key
blocks, and Japanese phone number formats.

Field *names* matching `password`, `token`, `secret`, `apiKey` and similar
are masked wholesale regardless of the value's shape — customize via
`Redactor.sensitiveKeyPattern`.

Add your own rules:

```dart
Logger.create(
  sink: sink,
  redactor: Redactor(
    rules: [
      ...builtInRedactionRules.where((r) => r.enabledByDefault),
      RedactionRule(name: 'ticket', pattern: RegExp(r'\bTICKET-\d{3,}\b')),
    ],
  ),
);
```

Use `Redactor.disabled()` only for local, throwaway debugging.

## Sinks

| Sink | Purpose |
|---|---|
| `JsonlFileSink` | Appends JSONL to a file with size-based rotation (`app.jsonl.1` … `.N`) |
| `ConsoleSink` | Human-readable, colorized terminal output |
| `MultiSink` | Fans out to several sinks; a failing sink is isolated, not fatal |
| `LevelFilterSink` | Wraps a sink with its own minimum level |
| `MemorySink` | Keeps events in memory — for tests and in-app log viewers |

Implement `LogSink` for anything else (shipping to a collector, forwarding to
Crashlytics/Sentry, and so on).

## Examples

- [`example/main.dart`](example/main.dart) — minimal quick start
- [`example/advanced_example.dart`](example/advanced_example.dart) — child
  loggers, dev/prod sink split, custom redaction rules, and using
  `DigestBuilder` directly

## Using it with Flutter

For automatic `FlutterError.onError` hooks, navigation breadcrumbs and native
(Kotlin/Swift) logging, see the [`ailog_flutter`](../ailog_flutter) add-on.

## Limitations

- `JsonlFileSink` requires a filesystem, so it's VM/native only. On the web,
  use `MemorySink` or your own `LogSink` (e.g. posting to a collector).
- **`JsonlFileSink` is isolate-local.** Two isolates each constructing their
  own sink over the same path will interleave writes and rotate
  independently. If you log from background isolates, give each one its own
  file path (`app.main.jsonl`, `app.worker.jsonl`) — `ailog_digest` accepts
  multiple files and merges them.
- Redaction is regex-based best-effort. Combine it with structured fields
  (key-name-based masking of `context`) as defense in depth rather than
  relying on pattern matching alone.
