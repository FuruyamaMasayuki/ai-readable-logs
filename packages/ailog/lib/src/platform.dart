/// Platform-specific hooks, resolved at compile time.
library;

export 'platform_io.dart' if (dart.library.js_interop) 'platform_web.dart';
