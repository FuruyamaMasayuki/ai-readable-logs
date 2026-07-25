import Flutter
import Foundation

/// The API native iOS code (Swift/Objective-C) calls to log into the same
/// JSONL file as the Dart side. See `Ailog.kt` (Android) for the mirrored
/// API.
///
/// Every call here goes over the MethodChannel into the Dart `Logger` —
/// same redaction, same sanitization, same causal-chain machinery as any
/// Dart-originated event. There is no independent native write on this
/// path; see `AilogFlutterPlugin`'s uncaught exception handler for the one
/// case (a crash after the engine is gone) where a direct file write
/// happens instead.
///
/// If no Flutter engine is attached yet, calls are queued in memory —
/// bounded to `maxPending` — and flushed in order once a channel attaches.
///
/// Swift errors do not carry a captured stack trace the way Java/Kotlin's
/// `Throwable` does, so `error`/`fatal` record `Thread.callStackSymbols`
/// captured at the `catch` site instead — the frames show where the error
/// was *logged*, not necessarily where it was originally thrown. Capture
/// as close to the `throw` as practical for the most useful trace.
///
/// Example:
/// ```swift
/// do {
///     try chargeCard()
/// } catch {
///     Ailog.error(error, context: ["orderId": orderId])
/// }
/// ```
public enum Ailog {
    private static let maxPending = 50
    private static let methodLogEvent = "logEvent"

    /// `lg` written for every event logged through this API.
    public static var defaultLoggerName = "ios"

    private static let lock = NSLock()
    private static var channel: FlutterMethodChannel?
    private static var pending: [[String: Any?]] = []

    static func attachChannel(_ newChannel: FlutterMethodChannel) {
        lock.lock()
        channel = newChannel
        let queued = pending
        pending.removeAll()
        lock.unlock()

        for args in queued {
            invoke(newChannel, args)
        }
    }

    static func detachChannel(_ oldChannel: FlutterMethodChannel) {
        lock.lock()
        defer { lock.unlock() }
        if channel === oldChannel { channel = nil }
    }

    public static func trace(_ message: String, context: [String: Any?]? = nil, tags: [String]? = nil) {
        emit(level: "trace", message: message, context: context, tags: tags)
    }

    public static func debug(_ message: String, context: [String: Any?]? = nil, tags: [String]? = nil) {
        emit(level: "debug", message: message, context: context, tags: tags)
    }

    public static func info(_ message: String, context: [String: Any?]? = nil, tags: [String]? = nil) {
        emit(level: "info", message: message, context: context, tags: tags)
    }

    public static func warn(_ message: String, context: [String: Any?]? = nil, tags: [String]? = nil) {
        emit(level: "warn", message: message, context: context, tags: tags)
    }

    /// Logs `error` at `error` level. `message` overrides the summary
    /// shown; the raw error description is always kept as `err.m`.
    public static func error(
        _ error: Error,
        message: String? = nil,
        context: [String: Any?]? = nil,
        tags: [String]? = nil
    ) {
        emitError(level: "error", error: error, message: message, context: context, tags: tags)
    }

    /// Same as `error(_:message:context:tags:)` but at `fatal`.
    public static func fatal(
        _ error: Error,
        message: String? = nil,
        context: [String: Any?]? = nil,
        tags: [String]? = nil
    ) {
        emitError(level: "fatal", error: error, message: message, context: context, tags: tags)
    }

    private static func emit(level: String, message: String, context: [String: Any?]?, tags: [String]?) {
        send([
            "level": level,
            "message": message,
            "logger": defaultLoggerName,
            "context": context,
            "tags": tags,
        ])
    }

    private static func emitError(
        level: String,
        error: Error,
        message: String?,
        context: [String: Any?]?,
        tags: [String]?
    ) {
        let nsError = error as NSError
        let type = String(describing: Swift.type(of: error))
        let errorMessage = nsError.localizedDescription
        let frames = Array(Thread.callStackSymbols.prefix(12))

        send([
            "level": level,
            "message": message ?? errorMessage,
            "logger": defaultLoggerName,
            "context": context,
            "tags": tags,
            "error": [
                "type": type,
                "message": errorMessage,
                "frames": frames,
            ],
        ])
    }

    private static func send(_ args: [String: Any?]) {
        lock.lock()
        let currentChannel = channel
        if currentChannel == nil {
            if pending.count >= maxPending { pending.removeFirst() }
            pending.append(args)
            lock.unlock()
            return
        }
        lock.unlock()
        invoke(currentChannel!, args)
    }

    private static func invoke(_ channel: FlutterMethodChannel, _ args: [String: Any?]) {
        if Thread.isMainThread {
            channel.invokeMethod(methodLogEvent, arguments: args)
        } else {
            DispatchQueue.main.async {
                channel.invokeMethod(methodLogEvent, arguments: args)
            }
        }
    }
}
