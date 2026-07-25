/// Records app lifecycle transitions — foreground, background, termination.
///
/// This is cheap (a handful of events over a whole session) and repeatedly
/// decisive. "Crashes when you come back to the app" and "the timer kept
/// firing while backgrounded" are both invisible in a log that only shows
/// what the code did, and obvious in one that also shows where the app was.
/// A `resumed` two seconds before a crash is a lead on its own.
library;

import 'package:ailog/ailog.dart';
import 'package:flutter/widgets.dart';

/// Logs [AppLifecycleState] changes as `interaction`-style events.
///
/// ```dart
/// final lifecycle = AilogLifecycleObserver(logger)..install();
/// // ...
/// lifecycle.dispose();   // in tests, or if you tear the app down
/// ```
///
/// Events default to [LogLevel.trace], so they stay out of a production file
/// while remaining available as breadcrumbs — the same trade the rest of this
/// package makes. Raise [level] to `info` if you want them written.
class AilogLifecycleObserver with WidgetsBindingObserver {
  AilogLifecycleObserver(Logger logger, {this.level = LogLevel.trace})
      : _logger = logger.child('lifecycle');

  final Logger _logger;

  /// Level the transitions are logged at. See the class doc.
  final LogLevel level;

  bool _installed = false;
  AppLifecycleState? _previous;

  /// Registers with [WidgetsBinding]. Safe to call more than once.
  void install() {
    if (_installed) return;
    // A binding must exist before an observer can be added; calling this
    // before `runApp`/`ensureInitialized` would otherwise throw from inside
    // logging setup, which is precisely what a logger must never do.
    WidgetsFlutterBinding.ensureInitialized();
    WidgetsBinding.instance.addObserver(this);
    _installed = true;
  }

  /// Unregisters. Safe to call when never installed, and twice.
  void dispose() {
    if (!_installed) return;
    WidgetsBinding.instance.removeObserver(this);
    _installed = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == _previous) return;
    final from = _previous;
    _previous = state;

    _logger.interaction(
      'app ${state.name}',
      level: level,
      // The transition, not just the destination: `paused → resumed` and
      // `hidden → resumed` mean different things on iOS, and "which one
      // preceded the crash" is the question being asked.
      context: {if (from != null) 'from': from.name, 'to': state.name},
      tags: const ['lifecycle'],
    );
  }
}
