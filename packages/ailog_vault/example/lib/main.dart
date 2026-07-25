// A minimal app with a "share logs" button: ailog writes the JSONL,
// AilogVaultShare zips it with a fresh digest and opens the share sheet.
import 'dart:io';

import 'package:ailog/ailog.dart';
import 'package:ailog_flutter/ailog_flutter.dart';
import 'package:ailog_vault/ailog_vault.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

late final Logger logger;
late final AilogVaultShare logShare;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final support = await getApplicationSupportDirectory();
  final logDir = Directory('${support.path}/ailog');
  logger = Logger.create(
    sink: JsonlFileSink(path: '${logDir.path}/app.jsonl'),
  );
  logShare = AilogVaultShare(
    logDirectory: logDir,
    appName: 'ailog_vault_example',
    flush: () => logger.flush(),
  );

  AilogFlutter.install(logger);
  runAppGuarded(
    logger,
    () => runApp(const ExampleApp()),
    // Plain print() calls end up in the JSONL too — and therefore in the
    // shared zip.
    capturePrint: true,
  );
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('ailog_vault example')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(
                onPressed: () {
                  logger.info('button tapped', context: {'screen': 'home'});
                  print('a legacy print, also captured');
                },
                child: const Text('Log something'),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  try {
                    throw StateError('deliberate example failure');
                  } catch (error, stack) {
                    logger.error(error, stack);
                  }
                },
                child: const Text('Log an error'),
              ),
              const SizedBox(height: 32),
              Builder(
                builder: (context) => FilledButton.icon(
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Share logs'),
                  onPressed: () async {
                    // Zips app.jsonl (+ rotations) with a regenerated
                    // digest.md and opens the platform share sheet.
                    await logShare.share(context, subject: 'example logs');
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
