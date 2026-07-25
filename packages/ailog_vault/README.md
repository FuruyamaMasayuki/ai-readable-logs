# ailog_vault

One-tap sharing of [ailog](../ailog) output through
[log_vault](https://pub.dev/packages/log_vault)'s zip + share-sheet flow.

ailog produces the artifacts an AI can read — a JSONL event stream and a
Markdown digest. log_vault owns the export path users already understand:
zip the logs, open the platform share sheet. This package is the seam
between them, and deliberately nothing more.

## What ends up in the zip

```
my_app_logs_2026-07-25T12-00-00.zip
├── app.jsonl        ← the structured log (self-describing, first line is a legend)
├── app.jsonl.1      ← rotations, if any
├── digest.md        ← regenerated at share time; read this first
└── metadata.json    ← app name, timestamp, event/error counts
```

`digest.md` is rebuilt from the JSONL files on every dump, so it always
describes the files beside it. For most bug reports it is the only thing the
recipient — human or AI — needs to open.

## Install

```sh
flutter pub add ailog ailog_vault
```

Until the packages are on pub.dev, depend on them from the repository:

```yaml
dependencies:
  ailog_vault:
    git:
      url: https://github.com/FuruyamaMasayuki/ai-readable-logs
      path: packages/ailog_vault
```

## Usage

```dart
import 'dart:io';
import 'package:ailog/ailog.dart';
import 'package:ailog_vault/ailog_vault.dart';
import 'package:path_provider/path_provider.dart';

late final Logger logger;
late final AilogVaultShare logShare;

Future<void> initLogging() async {
  final dir = Directory('${(await getApplicationSupportDirectory()).path}/ailog');
  logger = Logger.create(sink: JsonlFileSink(path: '${dir.path}/app.jsonl'));
  logShare = AilogVaultShare(
    logDirectory: dir,
    appName: 'my_app',
    flush: () => logger.flush(),
  );
}

// In a "send logs" button:
onPressed: () => logShare.share(context, subject: 'my_app logs'),
```

No `LogVault.init()` is required — `AilogVaultShare` uses log_vault's
`LogDumper`/`ShareLogDumper` directly. If your app *also* logs through
log_vault into the same directory, its `log_YYYYMMDD.log` files are included
in the zip automatically.

### Without the share sheet

```dart
final zip = await logShare.dump(metadata: {'ticket': 'SUP-123'});
await uploadToSupport(zip);          // your own transport
await logShare.dispose();            // reclaim the temp zip

final digest = await logShare.writeDigest();   // just the summary, no zip
showPreview(digest.toMarkdown());
```

## Requirements

Depends on `log_vault >= 0.1.1` for `LogDumper.extraPatterns` — the hook
that lets the zip include `.jsonl`/`.md` files alongside log_vault's own
`.log` files.

## Verification status

The digest-writing half (`writeDigestForDirectory`) is pure Dart and covered
by tests in `test/`. The share half is a thin composition of log_vault's
`LogDumper` (whose `extraPatterns` behaviour is tested in log_vault itself)
and `ShareLogDumper`; the share sheet requires a device and is not covered
by automated tests here.
