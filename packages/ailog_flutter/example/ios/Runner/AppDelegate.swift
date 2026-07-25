import Flutter
import UIKit
import ailog_flutter

/// Demonstrates logging from native iOS code into the same JSONL file the
/// Dart side writes to.
///
/// Everything here goes through `Ailog`, which forwards over the
/// `dev.ailog/flutter` MethodChannel into the Dart `Logger` — so these lines
/// land in the same file, with the same redaction and sanitization, as
/// anything logged from Dart.
///
/// Note the ordering: the `Ailog.info` below runs before
/// `GeneratedPluginRegistrant.register` has attached the channel, so it is
/// queued in memory and flushed once the plugin registers. Calls made after
/// the app is running (like the ones the "5. Log from native" button
/// triggers, via `emitTestLog`) go straight through.
@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Queued: no channel yet. Flushed in order once the plugin registers.
    Ailog.info("app launching", tags: ["lifecycle"])

    GeneratedPluginRegistrant.register(with: self)

    Ailog.info("plugins registered", tags: ["lifecycle"])

    // Errors carry their stack frames across the bridge, and are
    // fingerprinted with the same algorithm the Dart side uses — so the same
    // native bug groups into one bucket in `ailog_digest` whether it arrived
    // over the channel or was written directly by the crash handler.
    do {
      try simulateNativeFailure()
    } catch {
      Ailog.error(error, context: ["screen": "launch"])
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    Ailog.debug("app became active", tags: ["lifecycle"])
  }

  override func applicationWillResignActive(_ application: UIApplication) {
    super.applicationWillResignActive(application)
    Ailog.debug("app will resign active", tags: ["lifecycle"])
  }

  private func simulateNativeFailure() throws {
    throw NSError(
      domain: "dev.ailog.example",
      code: 42,
      userInfo: [NSLocalizedDescriptionKey: "native-side example failure"]
    )
  }
}
