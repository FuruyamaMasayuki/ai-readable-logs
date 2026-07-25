# ailog_flutter

[`ailog`](../ailog) をFlutterアプリに接続するアドオン。フレームワークの
エラー通知経路（`FlutterError.onError` / `PlatformDispatcher.onError` /
`ErrorWidget.builder`）と画面遷移を自動でJSONLログに記録する。

## セットアップ

```dart
import 'package:ailog_flutter/ailog_flutter.dart';

void main() {
  final logger = Logger.create(
    sink: MultiSink([
      JsonlFileSink(path: '${Directory.systemTemp.path}/ailog/app.jsonl'),
      LevelFilterSink(ConsoleSink(), LogLevel.info),
    ]),
  );

  // FlutterError / PlatformDispatcher / ErrorWidget を自動フック。
  // 既存のハンドラ（Crashlytics, Sentryなど）は上書きせずchainされる。
  AilogFlutter.install(logger);

  runAppGuarded(logger, () {
    WidgetsFlutterBinding.ensureInitialized();
    runApp(MyApp(logger: logger));
  });
}
```

`runAppGuarded` はzoneレベルの `runZonedGuarded` 相当で、`body` 内の
すべてのログ呼び出し（非同期ギャップやフレームワークのコールバックを含む）
を1つのトレースに紐付け、捕捉されなかった例外も `fatal` として記録する。

## 画面遷移のトレース記録

```dart
MaterialApp(
  navigatorObservers: [AilogNavigatorObserver(logger)],
  // ...
)
```

push/pop/remove/replace が `info` イベントとしてJSONLに残るため、
「クラッシュ直前にどの画面を経由したか」がログだけで再構成できる。

## `AilogFlutter.install` のオプション

| オプション | 既定値 | 説明 |
|---|---|---|
| `recordFlutterErrors` | `true` | `FlutterError.onError` をフックし、フレームワーク/ビルドエラーを記録 |
| `recordPlatformDispatcherErrors` | `true` | `PlatformDispatcher.onError` をフックし、zoneを抜けた未捕捉エラーを `fatal` として記録 |
| `captureWidgetBuildErrors` | `true` | `ErrorWidget.builder` をフックし、赤画面/グレー画面の原因を記録（表示自体は変更しない） |

いずれも既存のハンドラを **置き換えずchain** する。`install` は
プロセス内で最初の1回のみ有効（多重登録による二重ログを防ぐため）。

## 注意

- `ailog_flutter` は `ailog` を再エクスポートしているので、両方を
  別々にimportする必要はない。
- ロガー本体のマスキング・サニタイズ・因果チェーンなどの挙動は
  すべて `ailog` 側の設定に従う。
