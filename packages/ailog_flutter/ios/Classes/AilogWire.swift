import Foundation

/// Wire-format primitives shared by `Ailog` (crash-time fallback writes)
/// and `AilogFlutterPlugin`. Mirrors
/// `packages/ailog_flutter/android/.../AilogWire.kt` and, transitively,
/// the Dart algorithms in `packages/ailog/lib/src/ids.dart` and
/// `normalizer.dart`, so that a fingerprint computed here for a given
/// error type + stack frames matches the fingerprint the Dart side would
/// compute for the *same* error via `errorFingerprintFromFrames` when it
/// arrives over the MethodChannel instead. `shortHash`/
/// `errorFingerprintFromFrames`/`normalizeMessage` were verified
/// byte-for-byte against the Dart implementation (and the Kotlin port) for
/// a set of reference inputs — see `AilogWireTest.kt` on the Android side
/// for those reference values. Keep this file in sync with both if the
/// algorithm ever changes.
///
/// Note: this file could not be compiled or run in the sandbox that
/// authored it (no Xcode/macOS toolchain available). It was written to
/// mirror the Kotlin implementation, which *was* verified against Dart
/// using a real Kotlin compiler. Treat it as reviewed-but-unbuilt until a
/// real iOS toolchain compiles and exercises it.
enum AilogHash {
    private static let fnvOffsetBasis: UInt64 = 0xcbf29ce4_84222325
    private static let fnvPrime: UInt64 = 0x0000_0100_0000_01b3

    /// Non-cryptographic 64-bit FNV-1a hash, matching `fnv1a64` in Dart.
    /// Iterates UTF-16 code units to match Dart's `String.codeUnitAt`
    /// (Dart strings are UTF-16 internally).
    static func fnv1a64(_ input: String, seed: UInt64 = fnvOffsetBasis) -> UInt64 {
        var hash = seed
        for unit in input.utf16 {
            hash ^= UInt64(unit)
            hash = hash &* fnvPrime // &* wraps silently on overflow, matching Dart/Kotlin's 64-bit math.
        }
        return hash
    }

    /// Short lowercase hex token, matching `shortHash` in Dart.
    static func shortHash(_ input: String, length: Int = 8) -> String {
        let hex = String(fnv1a64(input), radix: 16)
        let padded = String(repeating: "0", count: max(0, 16 - hex.count)) + hex
        let clamped = min(max(length, 1), 16)
        return String(padded.prefix(clamped))
    }
}

private enum AilogPatterns {
    // swiftlint:disable force_try
    static let number = try! NSRegularExpression(pattern: "(?<![A-Za-z_])\\d+(\\.\\d+)?")
    static let quoted = try! NSRegularExpression(pattern: "\"[^\"]*\"|'[^']*'")
    static let url = try! NSRegularExpression(pattern: "https?://\\S+")
    static let uuid = try! NSRegularExpression(
        pattern: "\\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\b",
        options: [.caseInsensitive]
    )
    static let path = try! NSRegularExpression(pattern: "(/[\\w.-]+){2,}")
    static let hexish = try! NSRegularExpression(pattern: "\\b[0-9a-f]{8,}\\b", options: [.caseInsensitive])
    static let whitespace = try! NSRegularExpression(pattern: "\\s+")
    // swiftlint:enable force_try
}

private func replaceAll(_ regex: NSRegularExpression, in text: String, with replacement: String) -> String {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
}

/// Best-effort port of `normalizeMessage` from the Dart package. Only used
/// as the fingerprint fallback when an error has no stack frames at all
/// (rare for native exceptions); when frames are present,
/// `errorFingerprintFromFrames` never reaches this function.
func normalizeMessage(_ message: String) -> String {
    var normalized = message.lowercased()
    normalized = replaceAll(AilogPatterns.url, in: normalized, with: "<url>")
    normalized = replaceAll(AilogPatterns.uuid, in: normalized, with: "<uuid>")
    normalized = replaceAll(AilogPatterns.quoted, in: normalized, with: "<str>")
    normalized = replaceAll(AilogPatterns.path, in: normalized, with: "<path>")
    normalized = replaceAll(AilogPatterns.hexish, in: normalized, with: "<hex>")
    normalized = replaceAll(AilogPatterns.number, in: normalized, with: "<n>")
    normalized = replaceAll(AilogPatterns.whitespace, in: normalized, with: " ")
    return normalized.trimmingCharacters(in: .whitespaces)
}

/// Mirrors `errorFingerprintFromFrames` in Dart exactly for the
/// frames-present case: `type|frame1|frame2|...` hashed with `AilogHash`.
func errorFingerprintFromFrames(
    errorType: String,
    message: String,
    frames: [String],
    framesInFingerprint: Int = 5
) -> String {
    var signature = errorType
    if frames.isEmpty {
        signature += "|" + normalizeMessage(message)
    } else {
        for frame in frames.prefix(framesInFingerprint) {
            signature += "|" + frame
        }
    }
    return AilogHash.shortHash(signature)
}

/// A structured error, ready to be embedded in a JSONL `err` field.
struct NativeError {
    let type: String
    let message: String
    let frames: [String]

    init(type: String, message: String, frames: [String] = []) {
        self.type = type
        self.message = message
        self.frames = frames
    }

    var fingerprint: String {
        errorFingerprintFromFrames(errorType: type, message: message, frames: frames)
    }
}

/// Minimal recursive JSON encoder — kept dependency-free on purpose, and
/// used instead of `JSONSerialization` because the latter does not
/// guarantee key order, which matters for keeping this output readable
/// and consistent with the Dart/Kotlin writers.
///
/// Accepts `String`, `Bool`, `Int`, `Double`, `nil`, `[(String, Any?)]`
/// (ordered object) and `[Any?]` (array); anything else is stringified.
func encodeJson(_ value: Any?) -> String {
    var out = ""
    encodeJsonInto(value, &out)
    return out
}

private func encodeJsonInto(_ value: Any?, _ out: inout String) {
    switch value {
    case .none:
        out += "null"
    case let some as Bool:
        out += some ? "true" : "false"
    case let some as Int:
        out += String(some)
    case let some as Double:
        out += (some.isNaN || some.isInfinite) ? "\"\(some)\"" : String(some)
    case let some as String:
        encodeJsonString(some, &out)
    case let pairs as [(String, Any?)]:
        out += "{"
        for (index, pair) in pairs.enumerated() {
            if index > 0 { out += "," }
            encodeJsonString(pair.0, &out)
            out += ":"
            encodeJsonInto(pair.1, &out)
        }
        out += "}"
    case let array as [Any?]:
        out += "["
        for (index, item) in array.enumerated() {
            if index > 0 { out += "," }
            encodeJsonInto(item, &out)
        }
        out += "]"
    case let some?:
        encodeJsonString(String(describing: some), &out)
    }
}

private func encodeJsonString(_ value: String, _ out: inout String) {
    out += "\""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    out += "\""
}

/// Appends `ailog`-compatible JSONL lines directly to a file, bypassing
/// the MethodChannel entirely. This exists for exactly one purpose:
/// recording an uncaught exception when the Flutter engine may already be
/// torn down and therefore cannot be relied on to relay anything. See
/// `AilogFlutterPlugin`'s uncaught exception handler, which is the only
/// normal caller.
///
/// Lines written here carry their own `ses` (generated once per process)
/// and `seq` — a distinct writer identity from the Dart `Logger`, not a
/// continuation of its session. `ailog_digest` still groups them correctly
/// because grouping is by error fingerprint, not by session.
enum AilogJsonlWriter {
    private static let sessionId: String = randomHex(bytes: 16)
    private static var sequence = 0
    private static let lock = NSLock()

    private static func isoTimestampNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    static func write(path: String?, level: String, message: String, loggerName: String, error: NativeError?) {
        guard let path = path, !path.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        sequence += 1
        var pairs: [(String, Any?)] = [
            ("ts", isoTimestampNow()),
            ("lvl", level),
            ("msg", message),
            ("lg", loggerName),
            ("ses", sessionId),
            ("seq", sequence),
        ]
        if let error = error {
            var errorPairs: [(String, Any?)] = [
                ("t", error.type),
                ("m", error.message),
                ("fp", error.fingerprint),
            ]
            if !error.frames.isEmpty {
                errorPairs.append(("fr", error.frames))
            }
            pairs.append(("err", errorPairs))
        }

        let line = encodeJson(pairs) + "\n"
        guard let data = line.data(using: .utf8) else { return }

        do {
            let fileURL = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            // Directory may already exist, or be uncreatable. Either way, fall
            // through and let open() decide — a crash-time write must never
            // throw further.
        }

        // O_APPEND, not seek-then-write. The kernel resolves the offset as
        // part of the same write() call, so a Dart isolate appending to the
        // same file concurrently can't cause this line to land at a stale
        // offset and clobber theirs. This mirrors the Kotlin writer, which
        // gets the same guarantee via FileOutputStream(file, append = true).
        let descriptor = path.withCString { cPath in
            open(cPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        }
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }

        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let n = write(descriptor, base + written, buffer.count - written)
                // A short write is legal; retry the remainder. Give up on a
                // hard error rather than spinning inside a crash handler.
                if n <= 0 { break }
                written += n
            }
        }
    }
}

private func randomHex(bytes: Int) -> String {
    var result = ""
    for _ in 0..<bytes {
        result += String(format: "%02x", UInt8.random(in: 0...255))
    }
    return result
}
