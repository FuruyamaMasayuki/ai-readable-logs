package dev.ailog.ailog_flutter

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlin.system.exitProcess

/**
 * Flutter plugin entry point. Wires the `dev.ailog/flutter` MethodChannel
 * in both directions:
 *
 *  - **Dart → native**: handles `configure` (stores the JSONL file path
 *    used by the crash-time fallback writer) and `emitTestLog` (a
 *    round-trip smoke test — see the example app).
 *  - **Native → Dart**: [Ailog]'s `trace`/`info`/`warn`/`error`/`fatal`
 *    calls are sent out over this same channel and land in
 *    `AilogNativeBridge` on the Dart side.
 *
 * Also installs (once per process) an uncaught exception handler that
 * writes crash events directly to the configured JSONL file via
 * [AilogJsonlWriter], for the case where the exception unwinds after the
 * Flutter engine is no longer available to relay it over the channel. That
 * handler always chains to whatever handler was previously installed, so
 * normal Android crash reporting (Play Console, Crashlytics, ...) and
 * process-termination behavior are unaffected.
 */
class AilogFlutterPlugin : FlutterPlugin, MethodCallHandler {
    private var channel: MethodChannel? = null

    companion object {
        private var crashHandlerInstalled = false
        private var configuredLogFilePath: String? = null
        private val installLock = Any()

        private fun installCrashHandlerOnce() {
            synchronized(installLock) {
                if (crashHandlerInstalled) return
                crashHandlerInstalled = true

                val previous = Thread.getDefaultUncaughtExceptionHandler()
                Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
                    try {
                        val frames =
                            throwable.stackTrace.take(20).map { element ->
                                "${element.className}.${element.methodName}(${element.fileName}:${element.lineNumber})"
                            }
                        AilogJsonlWriter.write(
                            path = configuredLogFilePath,
                            level = "fatal",
                            message = throwable.message ?: throwable.javaClass.name,
                            loggerName = Ailog.defaultLoggerName,
                            error =
                                NativeError(
                                    type = throwable.javaClass.name,
                                    message = throwable.message ?: throwable.javaClass.name,
                                    frames = frames,
                                ),
                        )
                    } catch (_: Throwable) {
                        // Never let crash logging itself mask the original crash.
                    }

                    if (previous != null) {
                        previous.uncaughtException(thread, throwable)
                    } else {
                        // No prior handler: replicate Android's default
                        // termination so the process doesn't hang in a
                        // half-crashed state.
                        android.os.Process.killProcess(android.os.Process.myPid())
                        exitProcess(10)
                    }
                }
            }
        }
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        val newChannel = MethodChannel(flutterPluginBinding.binaryMessenger, "dev.ailog/flutter")
        newChannel.setMethodCallHandler(this)
        channel = newChannel
        Ailog.attachChannel(newChannel)
        installCrashHandlerOnce()
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "configure" -> {
                val path = (call.arguments as? Map<*, *>)?.get("logFilePath") as? String
                configuredLogFilePath = path
                result.success(null)
            }
            "emitTestLog" -> {
                Ailog.info(
                    "test message from native (${defaultPlatformLabel()})",
                    context = mapOf("origin" to "emitTestLog"),
                    tags = listOf("native", "smoke-test"),
                )
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel?.let { Ailog.detachChannel(it) }
        channel = null
    }

    private fun defaultPlatformLabel(): String = "Android ${android.os.Build.VERSION.RELEASE}"
}
