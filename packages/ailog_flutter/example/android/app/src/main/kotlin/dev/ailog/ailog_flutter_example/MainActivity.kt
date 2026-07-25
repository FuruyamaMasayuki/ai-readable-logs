package dev.ailog.ailog_flutter_example

import dev.ailog.ailog_flutter.Ailog
import io.flutter.embedding.android.FlutterActivity

/**
 * Demonstrates logging from native Android code into the same JSONL file the
 * Dart side writes to.
 *
 * Everything here goes through [Ailog], which forwards over the
 * `dev.ailog/flutter` MethodChannel into the Dart `Logger` — so these lines
 * land in the same file, with the same redaction and sanitization, as
 * anything logged from Dart.
 *
 * Note the ordering: [onCreate] runs *before* the Flutter engine has attached
 * the channel, so that call is queued in memory and flushed once the engine
 * comes up. Calls made after the app is running (like the ones the "5. Log
 * from native" button triggers, via `emitTestLog`) go straight through.
 */
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)

        // Queued: no engine yet. Flushed in order once the channel attaches.
        Ailog.info(
            "MainActivity created",
            context = mapOf("savedState" to (savedInstanceState != null)),
            tags = listOf("lifecycle"),
        )
    }

    override fun onResume() {
        super.onResume()
        Ailog.debug("MainActivity resumed", tags = listOf("lifecycle"))
    }

    override fun onPause() {
        super.onPause()
        Ailog.debug("MainActivity paused", tags = listOf("lifecycle"))

        // Errors carry their stack frames across the bridge, and are
        // fingerprinted with the same algorithm the Dart side uses — so the
        // same native bug groups into one bucket in `ailog_digest` whether it
        // arrived over the channel or was written directly by the crash
        // handler.
        try {
            simulateNativeFailure()
        } catch (e: IllegalStateException) {
            Ailog.error(e, context = mapOf("screen" to "main"))
        }
    }

    private fun simulateNativeFailure() {
        throw IllegalStateException("native-side example failure")
    }
}
