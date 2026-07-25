/// Flutter add-on for [ailog].
///
/// Provides automatic `FlutterError.onError` / `PlatformDispatcher.onError` /
/// `ErrorWidget.builder` hooks, structured recording of widget build errors,
/// navigation breadcrumbs, a zone-guarded `main()` helper, and a bridge that
/// lets native iOS/Android code log into the same JSONL output.
library ailog_flutter;

export 'package:ailog/ailog.dart';

export 'src/error_hooks.dart' show AilogFlutter;
export 'src/native_bridge.dart' show AilogNativeBridge;
export 'src/navigator_observer.dart' show AilogNavigatorObserver;
export 'src/run_app_guarded.dart' show runAppGuarded;
