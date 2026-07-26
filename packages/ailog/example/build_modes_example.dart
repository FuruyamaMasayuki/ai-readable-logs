// Controlling what logging does in debug / profile / release builds.
//
// Run it in each mode to see the difference:
//
//   dart run example/build_modes_example.dart      # debug (JIT)
//   dart compile exe example/build_modes_example.dart -o /tmp/app && /tmp/app
//
// The compiled binary is a release build, so `isReleaseBuild` is true there.
//
// ignore_for_file: avoid_print
library;

import 'package:ailog/ailog.dart';

/// Strategy 1 — quieter in release, not silent. **This is the default you
/// want.** The package exists for post-mortem analysis, and the failures
/// worth analyzing are the ones users hit in production; a release build
/// that logs nothing cannot describe them.
///
/// `enabled: true` is required: the default is `!isReleaseBuild`, so without
/// it a release build stays silent and `minimumLevel` is never consulted.
Logger quieterInRelease() => Logger.create(
      sink: MemorySink(),
      enabled: true,
      minimumLevel: byBuildMode(
        debug: LogLevel.trace, // everything while developing
        profile: LogLevel.info, // don't distort what you're measuring
        release: LogLevel.info, // keep the evidence, drop the noise
      ),
      // Causal chains are what make an error line self-contained, so keep
      // them in release — but a shorter chain costs less memory per trace.
      causalChainLength: byBuildMode(debug: 20, release: 8),
    );

/// Strategy 2 — off in release, with the sink eliminated at compile time.
///
/// Because `isReleaseBuild` is a `const`, the compiler folds this and drops
/// the dead branch. Verified against a real `dart compile exe` binary: the
/// log path string in the unused branch does not appear in the output at
/// all.
///
/// Reach for this when the log would hold data you are not willing to write
/// to a user's device, or when the build ships somewhere you could never
/// retrieve a file from. "Release should be fast" is usually *not* a good
/// enough reason — see the measurement at the bottom of this file.
Logger offInRelease() => isReleaseBuild
    ? Logger.disabled()
    : Logger.create(sink: JsonlFileSink(path: '.ailog/dev.jsonl'));

/// Strategy 3 — decided at runtime instead of by build mode.
///
/// Passing `enabled` explicitly overrides the build-mode default in both
/// directions: this logs in release when the user opted in, and stays quiet
/// in debug when they didn't. Use it for a remote config flag, a
/// "diagnostics" toggle in settings, a "help us debug this" switch.
///
/// It cannot eliminate anything, unlike strategy 2: the sink is still
/// constructed and the check is a real branch.
Logger togglable({required bool userOptedIn}) => Logger.create(
      sink: JsonlFileSink(path: '.ailog/app.jsonl'),
      enabled: userOptedIn,
    );

Future<void> main() async {
  print('build mode: ${currentBuildMode.name}');
  print('  isDebugBuild=$isDebugBuild  '
      'isProfileBuild=$isProfileBuild  '
      'isReleaseBuild=$isReleaseBuild');
  print('');

  // --- Strategy 1 -------------------------------------------------------
  // `enabled: true` opts back in: without it the default is `!isReleaseBuild`
  // and the compiled binary would keep 0 of 4, never reaching minimumLevel.
  final sink = MemorySink();
  final logger = Logger.create(
    sink: sink,
    enabled: true,
    minimumLevel: byBuildMode(debug: LogLevel.trace, release: LogLevel.info),
  );

  logger.trace('fine-grained detail');
  logger.debug('cache hit');
  logger.info('checkout started');
  logger.warn('retrying payment');

  print('strategy 1 (quieter in release): '
      '${sink.events.length} of 4 events kept '
      '(minimumLevel=${logger.minimumLevel.wireName})');

  // --- Strategy 2 -------------------------------------------------------
  final off = Logger.disabled();
  off.info('this goes nowhere');
  print('strategy 2 (disabled): isRecorded(error)='
      '${off.isRecorded(LogLevel.error)}');
  print('');

  // --- What a disabled call actually costs ------------------------------
  //
  // Worth measuring rather than assuming, because it is the number that
  // decides whether turning logging off in release is worth the blind spot.
  const iterations = 200000;
  final disabled = Logger.disabled();
  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    disabled.info('never emitted', context: const {'i': 1});
  }
  watch.stop();
  final nanosPerCall = watch.elapsedMicroseconds * 1000 / iterations;
  print('a call on a disabled logger: '
      '${nanosPerCall.toStringAsFixed(0)} ns');
  print('  (one bool test, ahead of all formatting and sanitizing)');

  // Guarding an expensive argument is still worth it when *building* the
  // argument is the cost — isRecorded covers breadcrumbs too, so it is the
  // honest question to ask.
  if (logger.isRecorded(LogLevel.debug)) {
    logger.debug('expensive', context: {'snapshot': _expensiveSnapshot()});
  }

  await logger.flush();
}

Map<String, Object?> _expensiveSnapshot() => {'built': 'only when recorded'};
