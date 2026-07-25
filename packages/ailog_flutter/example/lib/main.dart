// ailog_flutter の最小限の使用例。
//
// - AilogFlutter.install でフレームワークのエラー通知を自動記録
// - AilogNativeBridge.install でiOS/AndroidネイティブコードのログをDartと同じ
//   JSONLに合流させる(通常はMethodChannel経由、クラッシュ時のみネイティブ側が
//   直接ファイルに書き込む)
// - AilogNavigatorObserver で画面遷移をトレース記録
// - runAppGuarded でzoneレベルの未捕捉エラーも記録
//
// 5つのボタンでそれぞれの記録経路を実際に発火させて確認できる:
//   1. 画面遷移       -> AilogNavigatorObserver
//   2. 捕捉済みエラー -> 通常の logger.error()
//   3. Widgetビルドエラー -> ErrorWidget.builder フック
//   4. 非同期の未捕捉エラー -> PlatformDispatcher.onError フック
//   5. ネイティブ側からのログ -> Ailog.info(Kotlin/Swift) -> MethodChannel
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
      LevelFilterSink(ConsoleSink(), LogLevel.info),
    ]),
  );

  // 既存のエラーハンドラ(あれば)をchainしつつ、JSONLへの記録を追加する。
  AilogFlutter.install(logger);

  // iOS/Androidのネイティブ側に同じログファイルのパスを伝える。ネイティブ側は
  // 通常このパスを直接使わずMethodChannel経由でここに転送するが、クラッシュで
  // Flutterエンジンが落ちた後だけこのパスに直接書き込む(README参照)。
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
              child: const Text('1. 画面遷移をログに残す'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
                try {
                  throw StateError('card declined for alice@example.com');
                } catch (error, stack) {
                  logger.error(error, stack, context: {'screen': 'home'});
                }
              },
              child: const Text('2. 捕捉済みエラーをログに残す'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  settings: const RouteSettings(name: '/broken-widget'),
                  builder: (_) => const _BrokenWidget(),
                ),
              ),
              child: const Text('3. Widgetビルドエラーをログに残す'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
                // わざとtry/catchの外で投げる。PlatformDispatcher.onError
                // フック経由でfatalとして記録される。
                scheduleMicrotask(() {
                  throw StateError('uncaught error from a callback');
                });
              },
              child: const Text('4. 非同期の未捕捉エラーをログに残す'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => nativeBridge.requestNativeTestLog(),
              child: const Text('5. ネイティブ側からログを出す'),
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
      body: const Center(child: Text('このページの表示自体が route pushed として記録されている')),
    );
  }
}

/// build() が常に例外を投げるWidget。ErrorWidget.builder フックが
/// 起動することを確認するためのデモ用。
class _BrokenWidget extends StatelessWidget {
  const _BrokenWidget();

  @override
  Widget build(BuildContext context) {
    throw StateError('this widget always fails to build');
  }
}
