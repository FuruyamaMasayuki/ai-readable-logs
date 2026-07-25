package dev.ailog.ailog_flutter

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * These reference values were captured by running the equivalent Dart
 * functions in `packages/ailog` (`shortHash`, `errorFingerprintFromFrames`,
 * `normalizeMessage`) on the same inputs. They exist to catch any future
 * change that would silently break fingerprint parity between the
 * MethodChannel path (Dart computes the fingerprint) and the crash-time
 * direct-write path (this Kotlin code computes it) for the same error.
 */
class AilogWireTest {
    @Test
    fun `shortHash matches the Dart reference values`() {
        assertEquals("e936bdcce59d9180", AilogHash.shortHash("StateError|frame1", 16))
        assertEquals(
            "aa7f4d65159953e1",
            AilogHash.shortHash("NSException|AppDelegate.didFinishLaunching(App.swift:42)", 16),
        )
        assertEquals("a430d84680aabd0b", AilogHash.shortHash("hello", 16))
        assertEquals("f9dc2a5a7bfc6227", AilogHash.shortHash("checkout order 44", 16))
        assertEquals("cbf29ce484222325", AilogHash.shortHash("", 16))
    }

    @Test
    fun `shortHash never produces a negative-looking token`() {
        for (i in 0 until 2000) {
            val hash = AilogHash.shortHash("probe-$i", 16)
            assertTrue(hash.matches(Regex("^[0-9a-f]{16}$")), "probe-$i produced '$hash'")
        }
    }

    @Test
    fun `errorFingerprintFromFrames matches the Dart reference values`() {
        assertEquals(
            "7010ffb9",
            errorFingerprintFromFrames(
                "NSException",
                "crash",
                listOf("AppDelegate.didFinishLaunching(App.swift:42)", "main(main.m:10)"),
            ),
        )
        assertEquals(
            "a2659ba4",
            errorFingerprintFromFrames("E", "order 44 missing", emptyList()),
        )
    }

    @Test
    fun `errorFingerprintFromFrames ignores message differences when frames are present`() {
        val fp1 = errorFingerprintFromFrames("E", "message A", listOf("frame1"))
        val fp2 = errorFingerprintFromFrames("E", "message B", listOf("frame1"))
        assertEquals(fp1, fp2)
    }

    @Test
    fun `errorFingerprintFromFrames differs for different frames`() {
        val fp1 = errorFingerprintFromFrames("E", "x", listOf("frameA"))
        val fp2 = errorFingerprintFromFrames("E", "x", listOf("frameB"))
        assertNotEquals(fp1, fp2)
    }

    @Test
    fun `normalizeMessage matches the Dart reference output`() {
        val result =
            normalizeMessage(
                "Timeout after 3021ms for order 4471 at https://api.example.com/x \"abc\"",
            )
        assertEquals("timeout after <n>ms for order <n> at <url> <str>", result)
    }

    @Test
    fun `encodeJson escapes quotes, backslashes and newlines`() {
        val json = encodeJson(mapOf("a" to 1, "b" to "hi\"there\n", "c" to listOf(1, 2, null), "d" to null))
        assertEquals("""{"a":1,"b":"hi\"there\n","c":[1,2,null],"d":null}""", json)
    }

    @Test
    fun `NativeError fingerprint is derived from type and frames`() {
        val error = NativeError(type = "NSException", message = "x", frames = listOf("frame1"))
        assertEquals(errorFingerprintFromFrames("NSException", "x", listOf("frame1")), error.fingerprint)
    }

    @Test
    fun `AilogJsonlWriter appends a single parseable JSON line per call`() {
        val file = File.createTempFile("ailog_writer_test", ".jsonl")
        file.deleteOnExit()
        try {
            AilogJsonlWriter.write(file.absolutePath, "info", "hello", "android", null)
            AilogJsonlWriter.write(
                file.absolutePath,
                "fatal",
                "crash",
                "android",
                NativeError("E", "boom", listOf("f1")),
            )

            val lines = file.readLines()
            assertEquals(2, lines.size)
            assertTrue(lines[0].contains("\"lvl\":\"info\""))
            assertTrue(lines[1].contains("\"lvl\":\"fatal\""))
            assertTrue(lines[1].contains("\"fp\":"))
        } finally {
            file.delete()
        }
    }

    @Test
    fun `AilogJsonlWriter creates missing parent directories`() {
        val dir = File.createTempFile("ailog_writer_dir", "").apply { delete() }
        val nested = File(dir, "nested/app.jsonl")
        try {
            AilogJsonlWriter.write(nested.absolutePath, "info", "hello", "android", null)
            assertTrue(nested.exists())
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun `AilogJsonlWriter silently no-ops for a null or empty path`() {
        // Must not throw — this runs inside an uncaught exception handler.
        AilogJsonlWriter.write(null, "info", "hello", "android", null)
        AilogJsonlWriter.write("", "info", "hello", "android", null)
        assertFalse(File("").exists())
    }
}
