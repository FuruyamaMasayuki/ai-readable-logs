import Flutter
import UIKit

/// Flutter plugin entry point. Wires the `dev.ailog/flutter` MethodChannel
/// in both directions — see `Ailog.swift` for the native→Dart direction
/// and `AilogNativeBridge` (Dart) for the Dart-side handler.
///
/// Also installs (once per process) `NSSetUncaughtExceptionHandler`,
/// chaining to whatever handler was previously installed, so existing
/// crash reporters (Crashlytics, Sentry, ...) and default crash behavior
/// are unaffected.
///
/// **Coverage limitation** (read before relying on this for crash
/// reporting): `NSSetUncaughtExceptionHandler` only observes Objective-C
/// level `NSException`s. It does **not** see:
///  - Swift runtime traps — force-unwrapping `nil`, Swift array
///    out-of-bounds, integer overflow, `fatalError()` — these abort the
///    process directly via a signal, bypassing `NSException` entirely.
///  - Any other signal-raised crash (`SIGSEGV`, `SIGBUS`, `SIGILL`, ...).
///
/// Catching those requires an async-signal-safe C signal handler (no
/// Foundation, no Swift runtime, no allocation inside the handler), which
/// this plugin does not implement — that's a meaningfully larger and
/// riskier undertaking than the MethodChannel bridge this package is
/// centered on. For full native crash coverage, pair this with a
/// dedicated crash reporter and treat `Ailog`'s crash-time write as a
/// best-effort supplement, not a replacement.
public class AilogFlutterPlugin: NSObject, FlutterPlugin {
    private var channel: FlutterMethodChannel?

    private static let installLock = NSLock()
    private static var crashHandlerInstalled = false
    private static var configuredLogFilePath: String?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "dev.ailog/flutter", binaryMessenger: registrar.messenger())
        let instance = AilogFlutterPlugin()
        instance.channel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)

        Ailog.attachChannel(channel)
        installCrashHandlerOnce()
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "configure":
            if let args = call.arguments as? [String: Any], let path = args["logFilePath"] as? String {
                AilogFlutterPlugin.configuredLogFilePath = path
            }
            result(nil)
        case "emitTestLog":
            Ailog.info(
                "test message from native (iOS \(UIDevice.current.systemVersion))",
                context: ["origin": "emitTestLog"],
                tags: ["native", "smoke-test"]
            )
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private static func installCrashHandlerOnce() {
        installLock.lock()
        defer { installLock.unlock() }
        if crashHandlerInstalled { return }
        crashHandlerInstalled = true

        let previousHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            AilogJsonlWriter.write(
                path: AilogFlutterPlugin.configuredLogFilePath,
                level: "fatal",
                message: exception.reason ?? exception.name.rawValue,
                loggerName: Ailog.defaultLoggerName,
                error: NativeError(
                    type: exception.name.rawValue,
                    message: exception.reason ?? exception.name.rawValue,
                    frames: exception.callStackSymbols
                )
            )
            previousHandler?(exception)
        }
    }
}
