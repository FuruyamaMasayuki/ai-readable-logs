/// A recorded-but-not-yet-rendered event, held for causal chains.
///
/// Breadcrumbs are mostly `debug`/`trace` and mostly never rendered: they only
/// become visible if an error happens in the same trace while they are still
/// in the buffer. Sanitizing them eagerly would mean paying redaction and the
/// full recursive walk on every low-level log call — the very calls a
/// production `minimumLevel` is supposed to make free. So the raw values are
/// held and the work is deferred to [render], which runs at most once per
/// breadcrumb, only for the few that an error actually pulls in.
library;

import 'log_level.dart';
import 'sanitizer.dart';

class Breadcrumb {
  Breadcrumb({
    required this.time,
    required this.level,
    required this.message,
    required this.logger,
    required Map<String, Object?> context,
  }) :
        // Shallow-copied at record time. Callers routinely reuse or clear a
        // context map after logging, and a breadcrumb that reports the map's
        // *later* contents would be actively misleading. Copying the top
        // level is cheap; a nested object mutated afterwards can still shift,
        // which is the same caveat any deferred-rendering logger carries.
        context = context.isEmpty ? const {} : Map<String, Object?>.of(context);

  final DateTime time;
  final LogLevel level;
  final String message;
  final String logger;
  final Map<String, Object?> context;

  /// Renders this breadcrumb as a chain entry, applying [sanitizer] now.
  ///
  /// [relativeTo] turns the absolute timestamp into `dt`, a negative
  /// millisecond offset — shorter than a timestamp and easier to reason about
  /// ("the timeout fired 1.2s before the crash").
  Map<String, Object?> render(DateTime relativeTo, Sanitizer sanitizer) => {
        'dt': time.difference(relativeTo).inMilliseconds,
        'lvl': level.wireName,
        'msg': sanitizer.sanitizeText(message),
        if (logger != 'app') 'lg': logger,
        if (context.isNotEmpty) 'ctx': sanitizer.sanitizeMap(context),
      };
}
