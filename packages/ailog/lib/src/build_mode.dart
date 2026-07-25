/// Which build mode this code was compiled in, without depending on Flutter.
///
/// `dart.vm.product` and `dart.vm.profile` are defined by the compiler, not
/// by the caller, and they are what `package:flutter/foundation.dart`'s
/// `kReleaseMode`/`kProfileMode` are built on. Reading them here keeps this
/// package dependency-free while behaving identically in a Flutter app.
///
/// Because they are `const`, a condition written against them is folded at
/// compile time and the dead branch is removed by the AOT compiler — so
/// guarding *construction* eliminates the code entirely:
///
/// ```dart
/// final logger = isReleaseBuild
///     ? Logger.disabled()             // the JsonlFileSink is never built
///     : Logger.create(sink: JsonlFileSink(path: ...));
/// ```
///
/// Passing a flag at runtime (`Logger.create(enabled: !isReleaseBuild)`)
/// cannot do that: the sink is still constructed and the check is a real
/// branch. It is cheap — one bool, ahead of all formatting — but it is not
/// elimination. Use whichever the situation warrants; the difference is
/// stated plainly so the choice is informed.
library;

/// How the current binary was compiled.
enum BuildMode {
  /// JIT with assertions — `flutter run`, `dart run`, `dart test`.
  debug,

  /// AOT with instrumentation — `flutter run --profile`.
  profile,

  /// AOT, optimized — `flutter build`, `dart compile exe`.
  release,
}

/// True in a release build (`flutter build`, `dart compile exe`).
const bool isReleaseBuild = bool.fromEnvironment('dart.vm.product');

/// True in a profile build (`flutter run --profile`).
const bool isProfileBuild = bool.fromEnvironment('dart.vm.profile');

/// True in a debug build — including `dart run` and `dart test`.
const bool isDebugBuild = !isReleaseBuild && !isProfileBuild;

/// The current build mode.
const BuildMode currentBuildMode = isReleaseBuild
    ? BuildMode.release
    : (isProfileBuild ? BuildMode.profile : BuildMode.debug);

/// Picks a value for the current build mode.
///
/// The usual shape for a log level, where release should be quieter rather
/// than silent:
///
/// ```dart
/// Logger.create(
///   sink: sink,
///   minimumLevel: byBuildMode(
///     debug: LogLevel.trace,
///     profile: LogLevel.debug,
///     release: LogLevel.info,
///   ),
/// );
/// ```
///
/// [profile] defaults to [release], because a profile build is a
/// release-shaped build being measured — matching debug's verbosity there
/// would distort the thing being measured.
T byBuildMode<T>({
  required T debug,
  required T release,
  T? profile,
}) =>
    switch (currentBuildMode) {
      BuildMode.debug => debug,
      BuildMode.profile => profile ?? release,
      BuildMode.release => release,
    };
