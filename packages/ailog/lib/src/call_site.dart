/// Identifies *where* a log call was made, so a log line can be useful even
/// when the caller had nothing to say.
///
/// The motivating case: you want to know a code path executed, but writing a
/// message for it is busywork and the messages end up as noise
/// (`'here'`, `'step 2'`, `'in handler'`). [captureCallSite] lets
/// `logger.info()` — no message at all — record `checkout.dart:42
/// CartService.charge` instead, which is strictly more useful for tracing
/// execution than any hand-written "got here" string.
library;

import 'normalizer.dart';

/// The resolved location of a log call.
class CallSite {
  const CallSite({required this.location, required this.member});

  /// e.g. `package:my_app/checkout/cart.dart:42`
  final String location;

  /// e.g. `CartService.charge`. May be empty if the frame had no member.
  final String member;

  /// Rendered as the synthesized log message, e.g.
  /// `→ package:my_app/checkout/cart.dart:42 CartService.charge`.
  ///
  /// The arrow marks the line as a *checkpoint* — a "this code ran" record
  /// with no human-written message — so it is trivially greppable and an AI
  /// reading the file can tell it apart from a deliberate message.
  String render() => member.isEmpty ? '→ $location' : '→ $location $member';

  @override
  String toString() => render();
}

/// Members that only exist inside ailog's own logging path.
///
/// Location-based detection (`package:ailog/…`) is the primary signal, but it
/// does not survive compilation to JavaScript, where every frame points at
/// `main.dart.js`. Without a second signal the walk would stop on ailog's own
/// `_emit` and confidently report the logger's internals as the caller —
/// worse than reporting nothing, because it looks correct. Matching the
/// member name catches that case, since dart2js preserves method names in
/// unminified output.
const Set<String> _ailogMembers = {
  'Logger._emit',
  'Logger.log',
  'Logger.checkpoint',
  'Logger.trace',
  'Logger.debug',
  'Logger.info',
  'Logger.warn',
  'Logger.errorMessage',
  'captureCallSite',
};

/// Frames belonging to ailog itself. When a call site is captured from inside
/// `Logger.info()`, the top frames are always ailog's own plumbing; the
/// caller is the first frame *below* them.
bool _isAilogFrame(StackFrame frame) {
  if (frame.location.contains('package:ailog/') ||
      frame.location.contains('package:ailog_flutter/')) {
    return true;
  }
  return _ailogMembers.contains(frame.member);
}

/// Whether a frame is too generic to name a call site.
///
/// Under dart2js without source maps, the useful frames are gone and what
/// remains is the compiler's runtime (`Object.wrapException`,
/// `StackTrace_current`, …) pointing at `main.dart.js`. Reporting one of
/// those as "where your code is" is actively misleading, so treat a bundle
/// location with no recognizable Dart library as unusable.
bool _isOpaqueBundleFrame(StackFrame frame) {
  final location = frame.location;
  // Any JavaScript bundle, not just one named `main.dart.js`. Keying this on
  // Flutter web's default output name was too narrow: a plain
  // `dart compile js -o app.js`, a custom bundler name, or anything else
  // slipped through and reported a runtime-internal frame
  // (`→ app.js:3881 StackTrace_current`) as the user's call site — the exact
  // confident-but-wrong answer this function exists to prevent.
  if (!location.contains('.js')) return false;
  // A source-mapped frame resolves back to a real Dart position (`x.dart:42`);
  // those name real code and are fine. `main.dart.js:3881` does not — the
  // `.dart` there is part of the bundle's filename, not a source reference,
  // which is why this tests for `.dart:` and not merely `.dart`.
  return !location.contains('.dart:');
}

/// Walks the current stack and returns the first frame outside ailog.
///
/// Returns `null` when no usable frame can be found. That is not rare and
/// callers must handle it: non-symbolic AOT traces (`--obfuscate` /
/// `--split-debug-info`) parse to nothing, and some browsers emit frame
/// formats Dart cannot map back to source. `Logger.checkpoint` substitutes an
/// explicit "call site unavailable" message rather than an empty one, so the
/// degradation is visible in the log instead of looking like a caller bug.
/// [Logger.checkpointsResolveCallSites] lets an app detect it at startup.
///
/// Cost: capturing `StackTrace.current` is not free (roughly microseconds,
/// but it allocates). It is only paid when a log call omits its message, and
/// only once the event is known to be going somewhere — see `Logger._emit`.
CallSite? captureCallSite({StackTrace? stackTrace, int skipFrames = 0}) {
  final frames = parseStackTrace(
    stackTrace ?? StackTrace.current,
    maxFrames: 24,
  );

  var skipped = 0;
  for (final frame in frames) {
    if (_isAilogFrame(frame)) continue;
    if (!frame.isApp) continue;
    if (_isOpaqueBundleFrame(frame)) continue;
    if (skipped < skipFrames) {
      skipped++;
      continue;
    }
    return CallSite(location: frame.location, member: frame.member);
  }
  return null;
}
