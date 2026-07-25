# ailog

AI解析に最適化された、依存ゼロのPure Dart構造化ロガー。

人間がターミナルで読むログと、AIに解析させるログは最適な形が違う。
`ailog` は後者に振り切っている: 1行1JSON（JSONL）で出力し、各行が
**それ単体で診断に必要な情報を持つ** ように設計されている。

## なぜ

大量のログをAIに渡して原因調査させると、コストのほとんどは
「エラー直前の文脈を探すためにファイル全体を読ませる」ことに消える。
`ailog` はその手戻りをなくす:

- **トレース/セッション相関** — `startTrace` / `span` で発行したIDが
  `Zone` 経由で自動伝播。手動でIDを引き回す必要がない。
- **因果チェーン** — エラー行に、直前の同一トレース内イベントが
  自動的に埋め込まれる。1行読むだけで経緯がわかる。
- **エラー自動指紋化** — スタックトレースを正規化してハッシュ化し、
  同じバグの別発生を自動グルーピング。行番号のズレやメッセージ内の
  可変値（ID・数値）に左右されない。
- **機密情報の自動マスキング** — メール・トークン・カード番号などを
  正規表現+検証ロジックで検出し `[redacted:kind#hash]` に置換。
  同じ値は同じハッシュになるので、値自体は見えなくても
  「同一ユーザーが複数行に登場している」ことは追跡できる。
- **AI向けダイジェストCLI** — 数十万行のJSONLを、エラー発生頻度順に
  ランキングしたMarkdown/JSONの要約に圧縮する `ailog_digest` コマンド。

## インストール

```yaml
dependencies:
  ailog:
    path: ../ailog # または pub.dev 公開後は通常の version 指定
```

## 使い方

```dart
import 'package:ailog/ailog.dart';

Future<void> main() async {
  final logger = Logger.create(
    sink: MultiSink([
      JsonlFileSink(path: '.ailog/app.jsonl'),
      LevelFilterSink(ConsoleSink(), LogLevel.info), // 開発時は人間可読
    ]),
  );

  final scope = logger.startTrace(context: {'requestId': 'req-1'});
  await runWithScope(scope, () async {
    logger.info('checkout started', context: {'userEmail': 'alice@example.com'});

    await logger.span('charge_card', (span) async {
      // 失敗するとエラー・所要時間・因果チェーンが自動記録される
      await chargeCard();
    });
  });

  await logger.flush();
}
```

出力される1行 (整形済み):

```json
{
  "ts": "2026-07-25T10:09:32.405471Z",
  "lvl": "error",
  "msg": "Exception: card declined",
  "lg": "app",
  "tr": "2efd38d3...",
  "sp": "...",
  "ctx": { "requestId": "req-1" },
  "err": {
    "t": "_Exception",
    "m": "Exception: card declined",
    "fp": "56161699",
    "fr": ["checkout.dart:42 CartService.charge", "..."]
  },
  "chain": [
    { "dt": -24, "lvl": "info", "msg": "checkout started",
      "ctx": { "userEmail": "[redacted:email#892c8bf7]" } }
  ]
}
```

ファイルの先頭行には各キーの意味を説明する `_hdr` レコードが自動で
書き込まれるため、外部ドキュメントなしでAIがフォーマットを理解できる。

## サブシステムごとのロガー

```dart
final dbLogger = logger.child('db');
final httpLogger = logger.child('http');
```

`child` で作った全ロガーは、同じセッション・シーケンス番号・因果バッファを
共有する。トレース内で複数のサブシステムをまたいでも順序と相関が保たれる。

## サンプル

- [`example/main.dart`](example/main.dart) — 最小構成のクイックスタート
- [`example/advanced_example.dart`](example/advanced_example.dart) — 子ロガー、
  開発/本番でのシンク使い分け、カスタムマスキングルール、`DigestBuilder` を
  CLIを介さず直接使う例

## AI向けダイジェスト

```sh
dart run ailog:ailog_digest .ailog/app.jsonl
```

エラーを発生頻度順にランキングし、各グループの代表フレーム・直近の
因果チェーンをMarkdownで出力する。数十万行のログでも出力サイズは
`--max-groups` で上限を制御できる。

```sh
dart run ailog:ailog_digest .ailog/app.jsonl --format json --max-groups 10 -o digest.json
```

## 機密情報マスキング

デフォルトで有効なルール: メール、JWT、Bearerトークン、Basic認証URL、
AWS/GCP/GitHub/Slack/Stripeの各種キー、Luhn検証付きカード番号、
秘密鍵ブロック、日本の電話番号形式など。

`password` `token` `secret` `apiKey` のようなフィールド名は、値の中身に
関わらず丸ごとマスクされる（`Redactor.sensitiveKeyPattern` でカスタマイズ可）。

ローカルデバッグでマスキングを無効化したい場合のみ
`Redactor.disabled()` を使用する。

## Flutterで使う場合

`FlutterError.onError` などの自動フックが必要な場合は
[`ailog_flutter`](../ailog_flutter) アドオンパッケージを参照。

## 制限事項

- `JsonlFileSink` はVM/ネイティブ専用（ファイルシステムが必要）。
  Web上では `MemorySink` や独自の `LogSink` 実装（収集サーバーへの送信など）
  を使用すること。
- 機密情報マスキングは正規表現ベースのベストエフォート。
  構造化フィールド（`context` のキー名によるマスキング）と
  組み合わせて多層防御として使うことを推奨する。
