/// Share ailog output through log_vault.
///
/// ailog writes AI-readable JSONL; log_vault owns the zip + share-sheet
/// export path. This package is the seam: one call zips the JSONL files
/// together with a freshly generated `digest.md` and hands them to the
/// platform share sheet.
library ailog_vault;

export 'src/ailog_vault_share.dart' show AilogVaultShare;
export 'src/digest_writer.dart' show writeDigestForDirectory, jsonlFilePattern;
