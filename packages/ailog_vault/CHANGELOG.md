## 0.1.0

- Initial release: `AilogVaultShare` zips the ailog JSONL files together
  with a freshly generated `digest.md` and hands them to the platform share
  sheet via `log_vault`'s `LogDumper`/`ShareLogDumper`.
- `writeDigestForDirectory` — the pure-Dart half: builds a digest from every
  `.jsonl` file in a directory (oldest rotation first) and writes it beside
  them.
- Requires `log_vault >= 0.1.1` for `LogDumper.extraPatterns`.
