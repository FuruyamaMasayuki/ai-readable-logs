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

/// Frames belonging to ailog itself. When a call site is captured from inside
/// `Logger.info()`, the top frames are always ailog's own plumbing; the
/// caller is the first frame *below* them.
bool _isAilogFrame(StackFrame frame) =>
    frame.location.contains('package:ailog/') ||
    frame.location.contains('package:ailog_flutter/');

/// Walks the current stack and returns the first frame outside ailog.
///
/// Returns `null` when no usable frame can be found — on release builds with
/// obfuscated/stripped stack traces, or on platforms where
/// `StackTrace.current` yields nothing parseable. Callers must treat `null`
/// as "no call site available" and fall back to an empty message rather than
/// inventing one.
///
/// Cost: capturing `StackTrace.current` is not free (roughly microseconds,
/// but it allocates). It is only paid when a log call omits its message, and
/// only after the level filter has already passed — see `Logger._emit`.
CallSite? captureCallSite({StackTrace? stackTrace, int skipFrames = 0}) {
  final frames = parseStackTrace(
    stackTrace ?? StackTrace.current,
    maxFrames: 24,
  );

  var skipped = 0;
  for (final frame in frames) {
    if (_isAilogFrame(frame)) continue;
    if (!frame.isApp) continue;
    if (skipped < skipFrames) {
      skipped++;
      continue;
    }
    return CallSite(location: frame.location, member: frame.member);
  }
  return null;
}
