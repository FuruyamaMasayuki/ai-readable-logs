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

Ranks errors by occurrence count and prints, per group, the representative
frames and the causal chain of the most recent occurrence. Output size is
bounded with `--max-groups`.

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
