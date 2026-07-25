# ailog_flutter

[`ailog`](../ailog) をFlutterアプリに接続するアドオン。フレームワークの
エラー通知経路（`FlutterError.onError` / `PlatformDispatcher.onError` /
`ErrorWidget.builder`）と画面遷移を自動でJSONLログに記録する。iOS/Android
のネイティブコード（Kotlin/Swift）から同じJSONLファイルにログを出す
ブリッジも備える。

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

## ネイティブ(iOS/Android)からのログ出力

Kotlin/Swiftで実装したコード（プラグイン、バックグラウンド処理、既存の
ネイティブモジュールなど）からも同じJSONLファイルにログを出せる。

```dart
// Dart側: 通常のセットアップに加えて logFilePath を渡す。
final bridge = AilogNativeBridge.install(logger, logFilePath: logFile);
```

```kotlin
// Android (Kotlin) — app/src の任意の場所から:
import dev.ailog.ailog_flutter.Ailog

Ailog.info("payment started", context = mapOf("orderId" to orderId))

try {
    chargeCard()
} catch (e: PaymentException) {
    Ailog.error(e, context = mapOf("orderId" to orderId))
}
```

```swift
// iOS (Swift) — ios/Runner の任意の場所から:
import ailog_flutter

Ailog.info("payment started", context: ["orderId": orderId])

do {
    try chargeCard()
} catch {
    Ailog.error(error, context: ["orderId": orderId])
}
```

### 仕組みと制約

- **通常時**: `Ailog.*` 呼び出しはMethodChannel経由でDartの `Logger` に
  転送される。マスキング・サニタイズ・因果チェーンなど、Dart発のログと
  完全に同じ処理を通る。Flutterエンジンがまだアタッチされていない場合は
  メモリ上に一時的にキュー（最大50件）され、アタッチ後にまとめて送られる。
- **クラッシュ時のみ**: 未捕捉例外でFlutterエンジンが道連れで落ちている
  可能性がある場面に限り、ネイティブ側が `logFilePath` に直接JSONL行を
  追記する（Dartを一切経由しない）。このフォールバック用の
  `Thread.setDefaultUncaughtExceptionHandler`（Android）/
  `NSSetUncaughtExceptionHandler`（iOS）は、**既存のハンドラを必ずchain**
  するため、Crashlytics/Sentryなど既存のクラッシュレポーティングは
  そのまま動き続ける。
- クラッシュ時に直接書き込まれた行は、Dartセッションとは別の
  `ses`（プロセスごとに生成）と `seq` を持つ。`ailog_digest` はエラーの
  指紋（fingerprint）でグルーピングするため、経路が違っても同じバグは
  正しく1つのグループにまとまる。
- **クラッシュ捕捉範囲の非対称性に注意**:
  - **Android**: `Thread.setDefaultUncaughtExceptionHandler` は未捕捉の
    Java/Kotlin例外をほぼすべて捕捉する。
  - **iOS**: `NSSetUncaughtExceptionHandler` は Objective-C の
    `NSException` のみを捕捉する。Swiftランタイムのトラップ（強制
    アンラップ失敗、配列範囲外アクセス、`fatalError()` など）や
    シグナルベースのクラッシュ（`SIGSEGV` 等）は対象外
    ―― これらを完全に捕捉するには async-signal-safe な
    シグナルハンドラが必要で、このパッケージでは実装していない
    （Crashlytics/Sentry相当の本格的なクラッシュレポーティングとの
    併用を推奨する）。
- ネイティブ側の `Ailog.error/fatal` はスタックフレーム文字列から
  Dart側と**同一アルゴリズム**（FNV-1a64）で指紋を計算する。同じ型・
  同じフレームなら、MethodChannel経由でもクラッシュ時の直接書き込みでも
  同じフィンガープリントになることをKotlin実装側で検証済み
  （`android/src/test/kotlin/.../AilogWireTest.kt`）。iOS(Swift)側は
  同一ロジックで実装したが、この開発環境にXcode/macOSツールチェインが
  無いためビルド・実機検証はできていない。導入前に実機/シミュレータで
  一度動作確認することを推奨する。

## サンプル

[`example/`](example) に実際に `flutter run` できる最小アプリがある
（`android/`・`ios/` 込みのフル構成）。5つのボタンで5つの自動記録経路
（画面遷移・捕捉済みエラー・Widgetビルドエラー・非同期の未捕捉エラー・
ネイティブ側からのログ）をそれぞれ発火できる。詳細は
[`example/README.md`](example/README.md) を参照。

## 注意

- `ailog_flutter` は `ailog` を再エクスポートしているので、両方を
  別々にimportする必要はない。
- ロガー本体のマスキング・サニタイズ・因果チェーンなどの挙動は
  すべて `ailog` 側の設定に従う。
- v0.2.0からFlutterプラグイン（`android/`・`ios/`ディレクトリを持つ）
  になった。ネイティブ連携が不要なプロジェクトでも影響はない
  （native/フィールドを使わなければAndroid/iOSのコードは一切呼ばれない）。
