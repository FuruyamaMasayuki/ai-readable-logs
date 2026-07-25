package dev.ailog.ailog_flutter

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/**
 * The API native Android code (Kotlin/Java) calls to log into the same
 * JSONL file as the Dart side.
 *
 * Every call here goes over the MethodChannel into the Dart [Logger][ailog
 * Logger] — same redaction, same sanitization, same causal-chain
 * machinery as any Dart-originated event. There is no independent native
 * write on this path; see [AilogFlutterPlugin]'s uncaught exception
 * handler for the one case (a crash after the engine is gone) where a
 * direct file write happens instead.
 *
 * If no Flutter engine is attached yet (e.g. a call happens very early in
 * `Application.onCreate`, before `FlutterEngine` initializes), calls are
 * queued in memory — bounded to [MAX_PENDING] — and flushed in order once
 * a channel attaches. If no engine ever attaches, they are silently
 * dropped; there is no file to write them to independently of Dart.
 *
 * Example:
 * ```kotlin
 * try {
 *     chargeCard()
 * } catch (e: PaymentException) {
 *     Ailog.error(e, context = mapOf("orderId" to orderId))
 * }
 * ```
 */
object Ailog {
    private const val MAX_PENDING = 50
    private const val METHOD_LOG_EVENT = "logEvent"

    /** `lg` written for events that don't specify their own via a future API. */
    var defaultLoggerName: String = "android"

    private val lock = Any()
    private var channel: MethodChannel? = null
    private val pending = ArrayDeque<Map<String, Any?>>()
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

    internal fun attachChannel(newChannel: MethodChannel) {
        synchronized(lock) {
            channel = newChannel
            while (pending.isNotEmpty()) {
                invokeOnMain(newChannel, pending.removeFirst())
            }
        }
    }

    internal fun detachChannel(oldChannel: MethodChannel) {
        synchronized(lock) {
            if (channel === oldChannel) channel = null
        }
    }

    fun trace(message: String, context: Map<String, Any?>? = null, tags: List<String>? = null) =
        emit("trace", message, context, tags)

    fun debug(message: String, context: Map<String, Any?>? = null, tags: List<String>? = null) =
        emit("debug", message, context, tags)

    fun info(message: String, context: Map<String, Any?>? = null, tags: List<String>? = null) =
        emit("info", message, context, tags)

    fun warn(message: String, context: Map<String, Any?>? = null, tags: List<String>? = null) =
        emit("warn", message, context, tags)

    /** Logs [throwable] at `error`. [message] overrides the summary shown; the raw exception message is always kept as `err.m`. */
    fun error(
        throwable: Throwable,
        message: String? = null,
        context: Map<String, Any?>? = null,
        tags: List<String>? = null,
    ) = emitError("error", throwable, message, context, tags)

    /** Same as [error] but at `fatal`. */
    fun fatal(
        throwable: Throwable,
        message: String? = null,
        context: Map<String, Any?>? = null,
        tags: List<String>? = null,
    ) = emitError("fatal", throwable, message, context, tags)

    private fun emit(level: String, message: String, context: Map<String, Any?>?, tags: List<String>?) {
        send(
            mapOf(
                "level" to level,
                "message" to message,
                "logger" to defaultLoggerName,
                "context" to context,
                "tags" to tags,
            ),
        )
    }

    private fun emitError(
        level: String,
        throwable: Throwable,
        message: String?,
        context: Map<String, Any?>?,
        tags: List<String>?,
    ) {
        val type = throwable.javaClass.name
        val errorMessage = throwable.message ?: type
        send(
            mapOf(
                "level" to level,
                "message" to (message ?: errorMessage),
                "logger" to defaultLoggerName,
                "context" to context,
                "tags" to tags,
                "error" to
                    mapOf(
                        "type" to type,
                        "message" to errorMessage,
                        "frames" to frameStrings(throwable),
                    ),
            ),
        )
    }

    private fun frameStrings(throwable: Throwable, maxFrames: Int = 12): List<String> =
        throwable.stackTrace.take(maxFrames).map { element ->
            "${element.className}.${element.methodName}(${element.fileName}:${element.lineNumber})"
        }

    private fun send(args: Map<String, Any?>) {
        synchronized(lock) {
            val currentChannel = channel
            if (currentChannel == null) {
                if (pending.size >= MAX_PENDING) pending.removeFirst()
                pending.addLast(args)
                return
            }
            invokeOnMain(currentChannel, args)
        }
    }

    private fun invokeOnMain(target: MethodChannel, args: Map<String, Any?>) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            target.invokeMethod(METHOD_LOG_EVENT, args)
        } else {
            mainHandler.post { target.invokeMethod(METHOD_LOG_EVENT, args) }
        }
    }
}
