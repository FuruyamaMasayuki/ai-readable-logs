# ailog_flutter example

`ailog_flutter` の最小構成アプリ。実機/エミュレータ、またはWebで実行できる:

```sh
cd example
flutter pub get
flutter run
```

起動すると `JsonlFileSink` が `$TMPDIR/ailog_example/app.jsonl` に書き込まれる
(コンソールにも同じパスが表示される)。アプリ内の4つのボタンはそれぞれ
`ailog_flutter` の異なる自動記録経路を発火させる:

1. **画面遷移** — `AilogNavigatorObserver` が push/pop を `info` イベントとして記録
2. **捕捉済みエラー** — 通常の `logger.error()` 呼び出し
3. **Widgetビルドエラー** — `ErrorWidget.builder` フックが発火し、赤画面/グレー画面の
   原因を記録(表示自体は変更されない)
4. **非同期の未捕捉エラー** — `PlatformDispatcher.onError` フックが `fatal` として記録

操作後、書き出されたファイルをダイジェストにかけて確認できる:

```sh
dart run ../../ailog/bin/ailog_digest.dart "$TMPDIR/ailog_example/app.jsonl"
```
