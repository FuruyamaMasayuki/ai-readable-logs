package dev.ailog.ailog_flutter

import java.io.File
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.atomic.AtomicInteger
import kotlin.random.Random

/**
 * Wire-format primitives shared by [Ailog] (crash-time fallback writes) and
 * [AilogFlutterPlugin]. Kept dependency-free and mirrors the algorithms in
 * ailog's Dart implementation (`packages/ailog/lib/src/ids.dart` and
 * `normalizer.dart`) so that a fingerprint computed here for a given error
 * type + stack frames matches the fingerprint the Dart side would compute
 * for the *same* error via `errorFingerprintFromFrames` when it arrives
 * over the MethodChannel instead. That parity is what lets `ailog_digest`
 * group "the same native crash" into one bucket regardless of which path
 * (channel forward vs. direct crash-time write) produced a given line.
 */
internal object AilogHash {
    private val fnvOffsetBasis = java.lang.Long.parseUnsignedLong("cbf29ce484222325", 16)
    private const val FNV_PRIME = 0x100000001b3L

    /** Non-cryptographic 64-bit FNV-1a hash, matching `fnv1a64Hex` in Dart. */
    fun fnv1a64(input: String, seed: Long = fnvOffsetBasis): Long {
        var hash = seed
        for (element in input) {
            hash = hash xor element.code.toLong()
            // Kotlin Long multiplication wraps silently. Dart computes the same
            // value via two 32-bit halves (so it also builds for web); the two
            // are verified equal against shared fixtures in AilogWireTest.
            hash *= FNV_PRIME
        }
        return hash
    }

    /** Short lowercase hex token, matching `shortHash` in Dart. */
    fun shortHash(input: String, length: Int = 8): String {
        // Long.toHexString treats the value as unsigned, so this never
        // produces a leading '-' the way naive signed formatting would.
        val hex = java.lang.Long.toHexString(fnv1a64(input)).padStart(16, '0')
        return hex.substring(0, length.coerceIn(1, 16))
    }
}

private val numberPattern = Regex("(?<![A-Za-z_])\\d+(\\.\\d+)?")
private val quotedPattern = Regex("\"[^\"]*\"|'[^']*'")
private val urlPattern = Regex("https?://\\S+")
private val uuidPattern =
    Regex("\\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\b", RegexOption.IGNORE_CASE)
private val pathPattern = Regex("(/[\\w.-]+){2,}")
private val hexishPattern = Regex("\\b[0-9a-f]{8,}\\b", RegexOption.IGNORE_CASE)
private val whitespacePattern = Regex("\\s+")

/**
 * Best-effort port of `normalizeMessage` from the Dart package. Only used
 * as the fingerprint fallback when an error has no stack frames at all
 * (rare for native exceptions); when frames are present, [errorFingerprintFromFrames]
 * never reaches this function, so exact byte-for-byte parity with Dart's
 * ICU-backed regex engine is not required for correctness in the common
 * case.
 */
internal fun normalizeMessage(message: String): String {
    var normalized = message.lowercase(Locale.US)
    normalized = urlPattern.replace(normalized, "<url>")
    normalized = uuidPattern.replace(normalized, "<uuid>")
    normalized = quotedPattern.replace(normalized, "<str>")
    normalized = pathPattern.replace(normalized, "<path>")
    normalized = hexishPattern.replace(normalized, "<hex>")
    normalized = numberPattern.replace(normalized, "<n>")
    normalized = whitespacePattern.replace(normalized, " ").trim()
    return normalized
}

/**
 * Mirrors `errorFingerprintFromFrames` in Dart exactly for the
 * frames-present case: `type|frame1|frame2|...` hashed with [AilogHash].
 */
internal fun errorFingerprintFromFrames(
    errorType: String,
    message: String,
    frames: List<String>,
    framesInFingerprint: Int = 5,
): String {
    val signature = StringBuilder(errorType)
    if (frames.isEmpty()) {
        signature.append('|').append(normalizeMessage(message))
    } else {
        for (frame in frames.take(framesInFingerprint)) {
            signature.append('|').append(frame)
        }
    }
    return AilogHash.shortHash(signature.toString())
}

/** A structured error, ready to be embedded in a JSONL `err` field. */
internal data class NativeError(
    val type: String,
    val message: String,
    val frames: List<String> = emptyList(),
) {
    val fingerprint: String
        get() = errorFingerprintFromFrames(type, message, frames)
}

/** Minimal recursive JSON encoder — kept dependency-free on purpose. */
internal fun encodeJson(value: Any?): String {
    val builder = StringBuilder()
    encodeJsonInto(value, builder)
    return builder.toString()
}

private fun encodeJsonInto(value: Any?, out: StringBuilder) {
    when (value) {
        null -> out.append("null")
        is Boolean -> out.append(value.toString())
        is Int, is Long -> out.append(value.toString())
        is Double -> out.append(if (value.isNaN() || value.isInfinite()) "\"$value\"" else value.toString())
        is Float -> out.append(if (value.isNaN() || value.isInfinite()) "\"$value\"" else value.toString())
        is String -> encodeJsonString(value, out)
        is Map<*, *> -> {
            out.append('{')
            var first = true
            for ((key, v) in value) {
                if (!first) out.append(',')
                first = false
                encodeJsonString(key.toString(), out)
                out.append(':')
                encodeJsonInto(v, out)
            }
            out.append('}')
        }
        is Iterable<*> -> {
            out.append('[')
            var first = true
            for (item in value) {
                if (!first) out.append(',')
                first = false
                encodeJsonInto(item, out)
            }
            out.append(']')
        }
        else -> encodeJsonString(value.toString(), out)
    }
}

private fun encodeJsonString(value: String, out: StringBuilder) {
    out.append('"')
    for (c in value) {
        when (c) {
            '"' -> out.append("\\\"")
            '\\' -> out.append("\\\\")
            '\n' -> out.append("\\n")
            '\r' -> out.append("\\r")
            '\t' -> out.append("\\t")
            else -> {
                if (c.code < 0x20) {
                    out.append("\\u").append(c.code.toString(16).padStart(4, '0'))
                } else {
                    out.append(c)
                }
            }
        }
    }
    out.append('"')
}

/**
 * Appends `ailog`-compatible JSONL lines directly to a file, bypassing the
 * MethodChannel entirely. This exists for exactly one purpose: recording an
 * uncaught exception when the Flutter engine may already be torn down and
 * therefore cannot be relied on to relay anything. See
 * [AilogFlutterPlugin]'s uncaught exception handler, which is the only
 * normal caller.
 *
 * Lines written here carry their own `ses` (generated once per process) and
 * `seq` — a distinct writer identity from the Dart [Logger], not a
 * continuation of its session. `ailog_digest` still groups them correctly
 * because grouping is by error fingerprint, not by session.
 */
internal object AilogJsonlWriter {
    private val sessionId = randomHex(16)
    private val sequence = AtomicInteger(0)
    private val writeLock = Any()

    private fun isoTimestampNow(): String {
        val format =
            SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }
        return format.format(java.util.Date())
    }

    fun write(path: String?, level: String, message: String, loggerName: String, error: NativeError?) {
        if (path.isNullOrEmpty()) return
        val obj = LinkedHashMap<String, Any?>()
        obj["ts"] = isoTimestampNow()
        obj["lvl"] = level
        obj["msg"] = message
        obj["lg"] = loggerName
        obj["ses"] = sessionId
        obj["seq"] = sequence.incrementAndGet()
        if (error != null) {
            val errObj = LinkedHashMap<String, Any?>()
            errObj["t"] = error.type
            errObj["m"] = error.message
            errObj["fp"] = error.fingerprint
            if (error.frames.isNotEmpty()) errObj["fr"] = error.frames
            obj["err"] = errObj
        }
        val line = encodeJson(obj)

        synchronized(writeLock) {
            try {
                val file = File(path)
                file.parentFile?.mkdirs()
                file.appendText(line + "\n")
            } catch (_: Throwable) {
                // A failed crash-time write must never throw further — this
                // runs inside an uncaught exception handler.
            }
        }
    }
}

private fun randomHex(bytes: Int): String {
    val builder = StringBuilder(bytes * 2)
    repeat(bytes) {
        builder.append(Random.nextInt(0, 256).toString(16).padStart(2, '0'))
    }
    return builder.toString()
}
