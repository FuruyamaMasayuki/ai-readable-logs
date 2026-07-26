# ailog

A zero-dependency, pure Dart structured logger designed to be read by an AI.

A log you scroll through in a terminal and a log an AI diagnoses from want
different shapes. `ailog` commits fully to the second: one JSON object per
line (JSONL), where **each line carries what's needed to diagnose it on its
own**.

## Install

```sh
dart pub add ailog        # or: flutter pub add ailog
```

Until the package is on pub.dev, depend on it straight from the repository:

```yaml
dependencies:
  ailog:
    git:
      url: https://github.com/FuruyamaMasayuki/ai-readable-logs
      path: packages/ailog
```

## Simplest thing that works

```dart
import 'package:ailog/ailog.dart';

Future<void> main() async {
  final logger = Logger.create(sink: JsonlFileSink(path: '.ailog/app.jsonl'));

  logger.info('hello');
  try {
    throw Exception('card declined');
  } catch (error, stackTrace) {
    logger.error(error, stackTrace);
  }

  await logger.close();   // flushes; also stops the background flush timer
}
```

That writes `.ailog/app.jsonl`. Hand it to an AI as-is, or summarize it
first:

```sh
dart run ailog:ailog_digest .ailog/app.jsonl
```

Everything below is optional. Add it when you want it — traces to tie
related lines together, a console sink to watch while developing, filters
for when the file gets big.

> **Flutter:** a relative path like `.ailog/` is not writable on a device.
> Use `path_provider`, and see
> [`ailog_flutter`](../ailog_flutter/README.md) for the rest of the setup:
> ```dart
> final dir = await getApplicationSupportDirectory();
> JsonlFileSink(path: '${dir.path}/ailog/app.jsonl');
> ```

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

## Contents

**Getting started** — [Install](#install) ·
[Simplest thing that works](#simplest-thing-that-works) ·
[The full picture](#the-full-picture) · [Cheat sheet](#cheat-sheet) ·
[Examples](#examples)

**Writing logs** — [Levels](#levels) ·
[Traces and spans](#traces-and-spans) ·
[Checkpoints](#checkpoints--logging-where-not-what) ·
[Capturing `print()`](#capturing-plain-print-calls) ·
[User interactions](#user-interactions) ·
[Per-subsystem loggers](#per-subsystem-loggers) ·
[Build modes](#debug--profile--release-builds)

**Reading logs** — [AI digest](#ai-digest) ·
[Filtering for an AI](#sending-logs-to-an-ai-without-sending-junk) ·
[Getting a string](#getting-the-log-as-a-string)

**Operational** — [Redaction](#redaction) · [Sinks](#sinks) ·
[Performance](#performance) · [Limitations](#limitations)

## The full picture

The same program with everything switched on — two sinks, a trace, a timed
span. Compare it with the minimal version above; every addition is optional
and independently useful.

```dart
import 'package:ailog/ailog.dart';

Future<void> main() async {
  // Create one Logger per process. MultiSink fans each event out to every
  // sink given to it — the two below don't have to agree on what to keep.
  final logger = Logger.create(
    sink: MultiSink([
      JsonlFileSink(path: '.ailog/app.jsonl'),          // everything, for the AI
      LevelFilterSink(ConsoleSink(), LogLevel.info),    // info+, human-readable in dev
    ]),
  );

  // startTrace begins one logical operation (here: one checkout) and
  // returns a LogScope carrying its trace id plus whatever context you pass.
  // runWithScope installs it for the duration of the callback: every log
  // call inside — including after an `await`, or from a callback that fires
  // later — automatically inherits the trace id and context. Nothing here
  // threads a request id through function signatures by hand.
  final scope = logger.startTrace(context: {'requestId': 'req-1'});
  await runWithScope(scope, () async {
    // Level, message, structured context. The email is redacted before it
    // reaches any sink — see "Redaction" further down.
    logger.info('checkout started', context: {'userEmail': 'a@example.com'});

    // span() times one step and closes it automatically on return or throw.
    await logger.span('charge_card', (span) async {
      // On failure: the error, its duration, a stable fingerprint, and the
      // causal chain (the events that happened just before it in this same
      // trace — including 'checkout started' above) are all recorded
      // automatically, and the exception still propagates to whatever
      // catches it outside this block.
      await chargeCard();
    });
  });

  // Pushes buffered lines to disk, then releases the sink. Don't stop at
  // flush(): JsonlFileSink runs a background timer to auto-flush, and only
  // close() cancels it. In a short-lived script like this one, flush()
  // alone leaves that timer running and the process never exits.
  await logger.flush();
  await logger.close();
}
```

Ordinary `print()` calls can be captured into the same file — see
["Capturing plain `print()` calls"](#capturing-plain-print-calls) below.

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
an AI can interpret the format with no external documentation. It also
carries the platform (OS, Dart version, pid, locale) — once, because the
answer is the same on every line. `Logger.create`'s `includePlatformContext`
merges those into each event instead, and measurably should not be your
default: on a 100-event file it grew the output 73%, from 182 to 315 bytes
per line.

## Cheat sheet

Everything you are likely to reach for, in one place.

### Creating a logger

```dart
Logger.create(sink: sink)                     // root logger
Logger.create(sink: sink, name: 'api')        // named
logger.child('db')                            // subsystem, shares session
Logger.disabled()                             // no-op; see Build modes
Logger.forTesting()                           // MemorySink, fixed session id
```

### Levels

```dart
logger.trace('...');    logger.debug('...');    logger.info('...');
logger.warn('...');     logger.errorMessage('...');
logger.error(e, stackTrace, message: '...');   // a caught exception
logger.fatal(e, stackTrace);                   // same, at fatal
logger.log(LogLevel.info, '...');              // level chosen at runtime
```

All of them take `context:` (a `Map<String, Object?>`) and `tags:`
(a `List<String>`). `error`/`fatal` take a thrown object and its stack, and
attach a fingerprint, normalized frames and the causal chain automatically.

`errorMessage` exists because `error` requires a thrown object — use it when
something failed but nothing was thrown:

```dart
logger.errorMessage('payment rejected', context: {'code': 'insufficient'});
```

### Traces and spans

```dart
// One trace = one logical operation (a request, a tap, a job).
final scope = logger.startTrace(context: {'requestId': id});
await runWithScope(scope, () async { ... });

// A span = a measured step inside it. Duration and failure are automatic,
// and the exception still propagates.
await logger.span('charge_card', (span) async => gateway.charge());
logger.spanSync('parse', (span) => decode(bytes));

// Manual control when the work isn't a single callback.
final span = logger.startSpan('upload');
await runWithScope(span.scope, () async { ... });   // ← don't skip this
span.succeed();                   // or span.fail(error, stackTrace)
span.elapsedMs;                   // duration so far, before finishing
```

IDs propagate through `Zone`, so anything logged inside — including after an
`await`, inside a callback, or from a nested function — inherits them
without being passed a parameter.

**Prefer the callback forms.** `startSpan` only *creates* the span; it does
not install its scope, so logs written between `startSpan()` and
`succeed()` come out with no trace or span id at all unless you wrap them
in `runWithScope(span.scope, …)` yourself. `span()` and `spanSync()` do that
for you, and close the span on both return and throw. Reach for the manual
form only when the work genuinely isn't a single callback.

### User interactions

```dart
logger.interaction('checkout_pressed', context: {'items': 3});
```

Records what the *person* did. Defaults to `trace`, so at a production
`minimumLevel` these stay out of the file but are retained as breadcrumbs —
they appear embedded in the causal chain of whatever fails next:

```text
ERROR checkout failed [fp:7ed4a8d1]
  — causal chain —
    -8.2s  ▸ view_cart_pressed
    -5.1s  route pushed: /cart
    -0.3s  ▸ checkout_pressed
```

Pass the intent (`checkout_pressed`), not the button's caption — an intent
survives copy changes and translation and groups across them. See
[`ailog_flutter`](../ailog_flutter/README.md#user-interaction-logging) for
app lifecycle tracking and why there is deliberately no automatic
"log every tap".

### Guarding expensive context

```dart
if (logger.isRecorded(LogLevel.debug)) {      // includes breadcrumbs
  logger.debug('state', context: {'graph': graph.toDebugMap()});
}
```

`isEnabled(level)` asks only whether it reaches the sink; `isRecorded` also
counts breadcrumb retention, and is the honest question when the cost you
are avoiding is *building the argument*.

### Reading it back

```dart
buildDigest(events)                     // in-memory events → Digest
digestFromJsonl(text)                   // JSONL text → Digest
digest.toMarkdown()                     // for a chat with an AI
digest.toJson()                         // for a dashboard

memorySink.toJsonl()                    // the wire format, as a String
memorySink.toMarkdown()                 // digest only
memorySink.export(LogFilter.forAi).toReport()   // digest + kept events
```

### Lifecycle

```dart
await logger.flush();     // push buffered lines to disk — before exit,
                          // before sharing, before reading the file back
await logger.close();     // flush, then release the sink — see below
```

**In a script or CLI, call `close()`, not just `flush()`.** `JsonlFileSink`
schedules a periodic timer (`flushInterval`, default 2s) to auto-flush, and
only `close()` cancels it. A live `Timer` keeps the isolate alive, so a
program that calls `flush()` and returns from `main()` does not exit — it
hangs until killed. `flush()` alone is fine mid-program (before reading the
file back, before sharing); `close()` is what lets the process end.

A `JsonlFileSink` writes error-level events out immediately by default
(`flushOnErrorLevel`), because the buffered line you most regret losing is
the one explaining why the process died.

## Debug / profile / release builds

> **A release build logs nothing unless you opt in.** `enabled` defaults to
> `!isReleaseBuild`, so `Logger.create(sink: ...)` is fully active in debug
> and profile, and completely silent in release. Verified by compiling the
> same program with `dart compile exe`: `default → 0 events`,
> `enabled: true → 2 events`.
>
> Filling a user's device with diagnostics should be a decision you made,
> not something that starts happening because you added a dependency. One
> argument turns it back on:
>
> ```dart
> Logger.create(sink: sink, enabled: true);                    // always on
> Logger.create(sink: sink, enabled: userOptedIntoDiagnostics); // their choice
> ```
>
> Be deliberate about leaving it off, though. Production is where the
> failures you cannot reproduce live, and this package exists to make those
> analyzable — a release build that logs nothing cannot describe them. If
> the concern is volume rather than the existence of a file, opt in and
> raise the level instead:
>
> ```dart
> Logger.create(
>   sink: sink,
>   enabled: true,
>   minimumLevel: byBuildMode(debug: LogLevel.trace, release: LogLevel.info),
> );
> ```

`isDebugBuild`, `isProfileBuild`, `isReleaseBuild` and `currentBuildMode` are
`const`, read from the compiler-defined `dart.vm.product` / `dart.vm.profile`
— the same values `package:flutter/foundation.dart`'s `kReleaseMode` is built
on. This package stays dependency-free and behaves identically inside a
Flutter app.

### On in release, but quieter (recommended when you can retrieve the log)

```dart
Logger.create(
  sink: sink,
  enabled: true,              // ← required; the default is off in release
  minimumLevel: byBuildMode(
    debug: LogLevel.trace,    // everything while developing
    profile: LogLevel.info,   // don't distort what you're measuring
    release: LogLevel.info,   // keep the evidence, drop the noise
  ),
  causalChainLength: byBuildMode(debug: 20, release: 8),
);
```

Without `enabled: true` this logs nothing at all in release — the level
would never be consulted. Worth this configuration whenever you have a way
to get the file back (a share button, a support flow); worth leaving off
when you don't, since a log nobody collects is pure cost.

`byBuildMode` works for any value, not just levels. `profile` defaults to
the `release` value, because a profile build is a release-shaped build being
measured.

### Off in release, with the sink compiled out

```dart
final logger = isReleaseBuild
    ? Logger.disabled()
    : Logger.create(sink: JsonlFileSink(path: logPath));
```

Because the condition is `const`, the AOT compiler folds it and drops the
dead branch. **Verified**, not assumed: compiling this with
`dart compile exe` and searching the binary shows the unused branch's log
path string is absent, while a control string in live code is present.

### Decided at runtime instead of by build mode

```dart
Logger.create(sink: sink, enabled: userOptedIntoDiagnostics);
```

Passing `enabled` explicitly overrides the build-mode default in both
directions — this logs in release when the user has opted in, and stays
quiet in debug when they haven't. Use it for a remote flag, a settings
toggle, a "help us debug this" switch.

It cannot eliminate anything: the sink is still constructed and the check
is a real branch. That is the difference from the `const` form above.

### What a disabled call actually costs

Measured by [`example/build_modes_example.dart`](example/build_modes_example.dart)
over 200,000 calls, with a context map:

| Build | Per call on a disabled logger |
|---|---|
| release (`dart compile exe`) | **2 ns** |
| debug (JIT) | 41 ns |

That check sits ahead of all formatting, sanitizing, breadcrumb recording
and stack capture. Worth knowing before you decide: **"release builds should
be fast" is usually not a good enough reason to log nothing in
production** — and a release build that logs nothing cannot describe the
failures users actually hit, which is what this package exists for. Turning
it off entirely is the right call when the log would hold data you are not
willing to write to a user's device, or when the build ships somewhere you
could never retrieve a file from.

`enabled: false` also suppresses breadcrumbs, so nothing is retained for a
causal chain either — and `isEnabled`/`isRecorded` both report `false`, so
guarded expensive context is skipped too:

```dart
if (logger.isRecorded(LogLevel.debug)) {          // false when disabled
  logger.debug('state', context: {'graph': graph.toDebugMap()});
}
```

Spans and traces still run their bodies when logging is off — disabling the
log must never disable the program.

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
tagged `print`.

It is **additive, not an alternative**: it wraps the logger you already set
up and the code you already have, so `logger.info(...)` and `print(...)`
both end up in the same file. Nothing above needs to change to adopt it.

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
shows up twice (once raw, once formatted). In Flutter, `runAppGuarded(...,
capturePrint: true)` does the same thing with one flag.

`capturePrints` does **not** start a trace of its own. A captured line
inherits whatever scope is active at the moment the `print()` runs, exactly
like a `logger.info()` in the same place — so the line above, outside any
`runWithScope`, has no trace, while prints from inside `runApplication()`
carry whatever trace that code established:

```dart
capturePrints(logger, () {
  print('before any trace');                       // tr: absent
  runWithScope(logger.startTrace(), () {
    print('inside a trace');                       // tr: 8405fee7…
  });
});
```

### How it actually works

`print()` in Dart is not a direct syscall — every call is routed through
`Zone.current.print()`, and any code can install its own `Zone` with a
different `print` handler. `capturePrints` runs `body` inside exactly such a
zone: its handler receives every `print()` call made anywhere in that zone,
looks at the string, forwards it to the real console, and logs it as an
event through a child logger (named `print` by default, via `loggerName`).

That mechanism has consequences worth knowing, each verified rather than
assumed:

- **It does not care which file the call came from.** A `print()` inside a
  third-party package, called from deep in a dependency you've never opened,
  is captured exactly like one in your own code — confirmed by capturing a
  print from a plain top-level function with no `ailog` import at all. There
  is nothing to configure for this; it falls out of how zones work.
- **Scheduled work stays captured.** A `print()` inside a `Timer` callback or
  a `Future.delayed` continuation *created* inside `body` is still captured
  even though it fires later — Dart binds a `Timer`/`Future` to the zone it
  was scheduled in, not the zone active when it eventually runs. Confirmed
  for both.
- **The boundary is exact.** A `print()` before `capturePrints` is entered,
  or after it returns, reaches only the console — never the log. Confirmed.
- **A spawned `Isolate` is its own zone tree.** `Isolate.spawn` starts fresh;
  nothing about the parent zone — including this print capture — crosses
  into it. A `print()` inside the spawned isolate's entry point is not
  captured. Call `capturePrints` again inside the isolate if you need it
  there too.
- **One `print()` call is one event, newlines and all.** `print('a\nb\nc')`
  produces a single log line whose `msg` contains the embedded `\n`
  characters — it is not split into three events. If a library you're
  capturing prints multi-line blocks (a stack trace, a formatted table),
  expect one event holding all of it.

### Why prints from the logging pipeline don't loop back in

`ConsoleSink.usingPrint()` renders each event by calling `print()` itself.
Without a guard, that print would be captured as a *new* event, whose sink
would print again to render *that*, captured again, forever. `capturePrints`
tracks a `logging` flag: while a captured line is being handed to the
logger, any print made *during* that call — which can only be the logging
pipeline's own — is sent straight to the console and not re-captured.

The failure mode this prevents is not hypothetical. The same handler with
the guard removed, run once against a single real print call:

```text
the one real print call
[captured] the one real print call
[captured] [captured] the one real print call
[captured] [captured] [captured] the one real print call
...
```

Unbounded, since each simulated "capture" prints, and that print gets
captured again. The real implementation cannot do this — the guard makes
capture strictly non-recursive regardless of what sinks are attached.

### Telling captured lines apart later

Every captured event carries `lg: "print"` (or your `loggerName`) and
`tags: ["print"]`, specifically so you can find and eventually remove them:
`ailog_digest`'s digest groups by logger, so they show up separately from
real application events, and `LogFilter(loggers: {'print'})` isolates just
them when reading the file back. `loggers` is an allow-list — to *exclude*
captured prints instead, filter on `!event.tags.contains('print')` yourself,
or reduce `capturePrints`'s scope by wrapping only the code you haven't
migrated yet rather than all of `main`.

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

### Knowing when the digest is incomplete

Rotation deletes the oldest file by design, so a digest built from what
survives is a *partial* view — and silently reporting `Events: 63686` for a
run that emitted 100,000 invites exactly the wrong conclusion. `seq` makes
the gap computable, so the digest says so itself:

```text
- Events: 63686
- **Incomplete: at least 36314 more events existed and are not in this digest.**
  Older rotations were deleted, or not every file was supplied. Treat the
  counts below as lower bounds, and do not compute rates from them.
```

`seq` is monotonic from 1 within one session, so the arithmetic is exact
rather than heuristic: a lowest `seq` of 36315 means 36,314 events preceded
it. Gaps in the middle — a file you forgot to pass — are counted too.
Available programmatically as `digest.missingEvents`.

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

### Reading a file with human eyes

The JSONL file is deliberately machine-shaped — short keys, one line per
event. When *you* need to look at a recovered file (a device pull, a bug
report attachment) rather than summarize it, `--format pretty` replays it
exactly the way `ConsoleSink` would have shown it live:

```sh
dart run ailog:ailog_digest app.jsonl --format pretty
```

```text
14:47:41.966 INFO  [app] #cf262f6c checkout started requestId=req-1 userEmail=[redacted:email#28564e4b]
14:47:41.979 ERROR [app] #cf262f6c Bad state: card declined requestId=req-1
  StateError: Bad state: card declined [fp:7ed4a8d1]
    at checkout.dart:9 CartService.charge
  — causal chain (2 events) —
    -13ms  checkout started
    -4ms  cache miss
```

Colour when writing to a terminal, plain text with `-o file`. Non-JSON
lines mixed into the file (a stray print, a logcat banner from a tee'd
session) are passed through untouched rather than hidden.

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
| `JsonlPrintSink` | The same wire format as `JsonlFileSink`, through `print` — for capturing a live debug session; see below |
| `ConsoleSink` | Human-readable, colorized terminal output |
| `MultiSink` | Fans out to several sinks; a failing sink is isolated, not fatal |
| `LevelFilterSink` | Wraps a sink with its own minimum level |
| `MemorySink` | Keeps events in memory — for tests and in-app log viewers |

Implement `LogSink` for anything else (shipping to a collector, forwarding to
Crashlytics/Sentry, and so on).

### Console output on Flutter

`ConsoleSink` writes to `stdout` by default, which is right for CLIs and
servers — but on a Flutter **device** `stdout` is not routed to logcat or the
unified log, so those lines go nowhere you can see. Use the `print`-based
form there:

```dart
ConsoleSink.usingPrint()                    // print()
ConsoleSink(write: debugPrint)              // Flutter's rate-limited variant
ConsoleSink(write: (l) => developer.log(l)) // dart:developer
```

Colour is off by default for `usingPrint`, because the Flutter console,
logcat and the Xcode console all render ANSI escapes as literal characters.

Combining this with `capturePrints` is safe: the capture guard passes the
logging pipeline's own prints straight through instead of logging them
again, so a `print`-based sink inside a captured zone cannot loop.

### Capturing a debug session as a file

`flutter run` mirrors the app's `print` output into your terminal live, over
the same connection every other debug tool already uses — no `adb pull`, no
Xcode device menus. `JsonlPrintSink` prints the exact wire format
`JsonlFileSink` would write, one line per event, so that session transcript
doubles as the log file:

```dart
Logger.create(sink: MultiSink([fileSink, JsonlPrintSink(write: debugPrint)]))
```

```sh
flutter run | tee session.log
grep -oE '\{.*\}' session.log > app.jsonl    # strip any logcat/IDE prefix
dart run ailog:ailog_digest app.jsonl
```

Pass `write: debugPrint`, not bare `print` — see "Console output on
Flutter" above for why plain `print` under load can silently drop lines on
Android. This is a debug-time convenience: there's no `_hdr` legend line
(nothing marks "start of file" in a live stream), and a dropped print is a
dropped event with no record that it happened. Reach for the real
`JsonlFileSink`, or one of `ailog_flutter`'s other ways to get a log off a
[real device](../ailog_flutter/README.md#getting-the-log-off-a-real-device),
when that matters more than convenience.

## Examples

All are runnable with `dart run example/<file>`.

| Example | What it shows |
|---|---|
| [`main.dart`](example/main.dart) | **Start here.** The smallest useful setup, end to end: file + console, one trace, redaction, a failing span, then the digest |
| [`walkthrough_example.dart`](example/walkthrough_example.dart) | The guided tour, in the order you meet things: subsystem loggers, checkpoints, then the digest and the filtered report side by side |
| [`advanced_example.dart`](example/advanced_example.dart) | Child loggers, dev/prod sink split, custom redaction rules, `DigestBuilder` used directly |
| [`ai_report_example.dart`](example/ai_report_example.dart) | A realistic connection-pool leak, then the three output forms — digest only, digest + events, raw JSONL — with their sizes side by side |
| [`build_modes_example.dart`](example/build_modes_example.dart) | The three ways to restrict logging per build mode, and a measurement of what a disabled call costs |

## Performance

Numbers below are from
[`benchmark/logging_benchmark.dart`](benchmark/logging_benchmark.dart),
compiled AOT on one ordinary Linux machine. **Run it yourself** before
trusting any of it for your context — that is what it is committed for:

```sh
dart compile exe benchmark/logging_benchmark.dart -o /tmp/bench && /tmp/bench
```

| Operation | Cost |
|---|---|
| `info`, no context | 3.03 µs |
| `info` with 6 context fields | 8.72 µs |
| `error` with a stack trace | 68.7 µs |
| `LogEvent.toJson` (per line written) | 1.01 µs |
| `debug` filtered out by `minimumLevel`¹ | **6 ns** |
| `debug` filtered, but retained as a breadcrumb² | 495 ns |
| Any call on a disabled logger | **5 ns** |

¹ with `causalChainLength: 0`, i.e. chains off.
² the default configuration: `breadcrumbLevel` below `minimumLevel`, so the
event is kept for a future causal chain even though it is not written.

What to take from this:

- **A filtered-out call is free.** 6 ns means you can leave `trace`/`debug`
  calls in hot paths and control them with `minimumLevel`. The check happens
  before anything is built, sanitized, or handed to a sink.
- **Causal chains are not free, but they are cheap.** The gap between rows 5
  and 6 — 6 ns vs 495 ns — is what breadcrumb retention costs. If a hot path
  makes that matter, raise `breadcrumbLevel` to equal `minimumLevel`
  (buffer only what you emit) or set `causalChainLength: 0`.
- **Errors are the expensive case**, at ~69 µs, dominated by stack-trace
  parsing and fingerprinting. That is fine for errors — until an error
  storm, which is what `RateLimitSink` is for. The stack is parsed *once*
  and shared between the displayed frames and the fingerprint; parsing twice
  was over half this cost before it was fixed.

Bounds that keep a bad day from becoming a worse one: context depth, string
length and collection size are capped (`SanitizerLimits`); the causal buffer
bounds both breadcrumbs per trace and traces tracked at once;
`RateLimitSink` collapses a repeating error into a burst plus a suppressed
count; and `JsonlFileSink` rotates by size and reports dropped events
through `droppedEvents` / `onError` rather than failing silently.

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
