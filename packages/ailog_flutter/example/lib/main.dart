// Minimal runnable example for ailog_flutter.
//
// - `AilogFlutter.install` records the framework's error channels
// - `AilogNativeBridge.install` merges native iOS/Android logging into the
//   same JSONL file (normally over the MethodChannel; only on a crash does
//   the native side write the file directly)
// - `AilogNavigatorObserver` records navigation
// - `runAppGuarded` catches anything that escapes the zone
//
// Each button fires one recording path:
//   1. Navigation        -> AilogNavigatorObserver
//   2. Caught error      -> a plain logger.error()
//   3. Widget build error-> ErrorWidget.builder hook
//   4. Uncaught async    -> PlatformDispatcher.onError hook
//   5. Native log        -> Ailog.info() in Kotlin/Swift -> MethodChannel
//   6. Checkpoint        -> logger.checkpoint(), message-free "this ran"
import 'dart:async';
import 'dart:io';

import 'package:ailog_flutter/ailog_flutter.dart';
import 'package:flutter/material.dart';

late final Logger logger;
late final AilogNativeBridge nativeBridge;

void main() {
  final logFile = '${Directory.systemTemp.path}/ailog_example/app.jsonl';
  logger = Logger.create(
    sink: MultiSink([
      JsonlFileSink(path: logFile),
      LevelFilterSink(ConsoleSink(), LogLevel.trace),
    ]),
    // Checkpoints default to `trace`, so keep the threshold there to see them
    // in this demo. Production would typically use `debug` or higher, which
    // filters them out at no cost.
    minimumLevel: LogLevel.trace,
  );

  // Adds JSONL recording while chaining any existing error handlers.
  AilogFlutter.install(logger);

  // Tell the native side which file to use for crash-time fallback writes.
  // In normal operation native logs come back over the MethodChannel and are
  // written by Dart; this path is only used when an uncaught native exception
  // may have taken the Flutter engine with it. See the package README.
  nativeBridge = AilogNativeBridge.install(logger, logFilePath: logFile);

  runAppGuarded(logger, () {
    WidgetsFlutterBinding.ensureInitialized();
    runApp(const AilogExampleApp());
  });

  // ignore: avoid_print
  print('ailog output: $logFile');
}

class AilogExampleApp extends StatelessWidget {
  const AilogExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ailog_flutter example',
      navigatorObservers: [AilogNavigatorObserver(logger)],
      home: const HomePage(),
      routes: {'/details': (_) => const DetailsPage()},
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ailog_flutter example')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ElevatedButton(
              onPressed: () => Navigator.of(context).pushNamed('/details'),
              child: const Text('1. Navigate (route breadcrumb)'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
                try {
                  // The email is redacted before it reaches the file.
                  throw StateError('card declined for alice@example.com');
                } catch (error, stack) {
                  logger.error(error, stack, context: {'screen': 'home'});
                }
              },
              child: const Text('2. Log a caught error'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  settings: const RouteSettings(name: '/broken-widget'),
                  builder: (_) => const _BrokenWidget(),
                ),
              ),
              child: const Text('3. Trigger a widget build error'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
                // Deliberately thrown outside any try/catch: recorded as
                // fatal via the PlatformDispatcher.onError hook.
                scheduleMicrotask(() {
                  throw StateError('uncaught error from a callback');
                });
              },
              child: const Text('4. Throw an uncaught async error'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => nativeBridge.requestNativeTestLog(),
              child: const Text('5. Log from native (Kotlin/Swift)'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
                // No message: the log line becomes the call site itself,
                // e.g. "→ main.dart:120 HomePage.build.<anonymous closure>".
                logger.checkpoint();
              },
              child: const Text('6. Record a checkpoint (no message)'),
            ),
          ],
        ),
      ),
    );
  }
}

class DetailsPage extends StatelessWidget {
  const DetailsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Details')),
      body: const Center(
        child: Text('Reaching this page was itself recorded as "route pushed"'),
      ),
    );
  }
}

/// A widget whose `build()` always throws, to demonstrate that the
/// `ErrorWidget.builder` hook records the cause without changing what the
/// user sees.
class _BrokenWidget extends StatelessWidget {
  const _BrokenWidget();

  @override
  Widget build(BuildContext context) {
    throw StateError('this widget always fails to build');
  }
}
