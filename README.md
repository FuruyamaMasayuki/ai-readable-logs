# ailog

AI解析に最適化された構造化JSONLロガー（Dart / Flutter向け）。

## パッケージ構成

| パッケージ | 説明 |
|---|---|
| [`packages/ailog`](packages/ailog) | 依存ゼロのPure Dartコア。CLI・サーバー・Flutterどこからでも使える |
| [`packages/ailog_flutter`](packages/ailog_flutter) | Flutterアドオン。`FlutterError.onError` 等の自動フックと画面遷移トレース |

詳細は各パッケージのREADMEを参照。

## 主な機能

- **JSONL出力** — 1行1JSON。先頭行にスキーマ凡例を自動同梱し、ファイル単体で
  AIが構造を理解できる。
- **トレース/セッション相関** — `Zone` ベースで自動伝播。手動でIDを引き回す
  必要がない。
- **因果チェーン** — エラー行に直前の同一トレース内イベントを自動同梱。
  1行読むだけで経緯がわかる。
- **エラー自動指紋化・グルーピング** — スタックトレースを正規化してハッシュ化。
  行番号のズレや可変値に左右されず同一バグをグルーピング。
- **機密情報の自動マスキング** — メール・トークン・カード番号などを検出し
  相関トークン付きで置換。値は隠しつつ関連性は追跡可能。
- **AI向けダイジェストCLI** (`ailog_digest`) — 大量のJSONLをエラー頻度順の
  Markdown/JSON要約に圧縮。

## クイックスタート

```dart
import 'package:ailog/ailog.dart';

void main() {
  final logger = Logger.create(
    sink: JsonlFileSink(path: '.ailog/app.jsonl'),
  );
  logger.info('hello');
}
```

```sh
dart run ailog:ailog_digest .ailog/app.jsonl
```
