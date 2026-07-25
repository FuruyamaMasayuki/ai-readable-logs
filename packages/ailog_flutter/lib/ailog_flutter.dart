/// Flutterアプリ向け ailog アドオン。
///
/// `FlutterError.onError` / `PlatformDispatcher.onError` の自動フック、
/// Widgetビルドエラーの構造化記録、画面遷移のトレース記録、
/// zoneレベルの捕捉付き `main()` ヘルパーを提供する。
library ailog_flutter;

export 'package:ailog/ailog.dart';

export 'src/error_hooks.dart' show AilogFlutter;
export 'src/native_bridge.dart' show AilogNativeBridge;
export 'src/navigator_observer.dart' show AilogNavigatorObserver;
export 'src/run_app_guarded.dart' show runAppGuarded;
