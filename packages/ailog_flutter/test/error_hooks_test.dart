import 'dart:ui' as ui;

import 'package:ailog_flutter/ailog_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late FlutterExceptionHandler? originalFlutterOnError;
  late ErrorWidgetBuilder originalErrorWidgetBuilder;
  late ui.ErrorCallback? originalPlatformOnError;

  setUp(() {
    AilogFlutter.resetForTesting();
    originalFlutterOnError = FlutterError.onError;
    originalErrorWidgetBuilder = ErrorWidget.builder;
    originalPlatformOnError = ui.PlatformDispatcher.instance.onError;
  });

  tearDown(() {
    FlutterError.onError = originalFlutterOnError;
    ErrorWidget.builder = originalErrorWidgetBuilder;
    ui.PlatformDispatcher.instance.onError = originalPlatformOnError;
  });

  test('install chains the previously installed FlutterError.onError', () {
    final sink = MemorySink();
    final logger = Logger.forTesting(sink: sink);

    var previousCalled = false;
    FlutterError.onError = (details) {
      previousCalled = true;
    };

    AilogFlutter.install(logger);

    FlutterError.onError!(
      FlutterErrorDetails(exception: StateError('widget build failed')),
    );

    expect(previousCalled, isTrue, reason: 'previous handler must still run');
    expect(sink.events, hasLength(1));
    expect(sink.events.single.logger, 'flutter');
    expect(sink.events.single.error!.type, 'StateError');
    expect(sink.events.single.tags, contains('flutter-error'));
  });

  test('install is a no-op the second time it is called', () {
    final sink = MemorySink();
    final logger = Logger.forTesting(sink: sink);

    AilogFlutter.install(logger);
    AilogFlutter.install(logger); // should not double-chain

    FlutterError.onError!(
      FlutterErrorDetails(exception: StateError('boom')),
    );

    expect(sink.events, hasLength(1));
  });

  test(
      'captureWidgetBuildErrors logs through ErrorWidget.builder '
      'without changing its output type', () {
    final sink = MemorySink();
    final logger = Logger.forTesting(sink: sink);
    final defaultBuilder = ErrorWidget.builder;

    AilogFlutter.install(logger);

    final details = FlutterErrorDetails(exception: StateError('bad widget'));
    final widget = ErrorWidget.builder(details);

    expect(sink.events, hasLength(1));
    expect(sink.events.single.tags, contains('widget-build'));
    expect(widget.runtimeType, defaultBuilder(details).runtimeType);
  });

  test('recordPlatformDispatcherErrors logs fatal and chains previous handler',
      () {
    final sink = MemorySink();
    final logger = Logger.forTesting(sink: sink);

    var previousCalled = false;
    ui.PlatformDispatcher.instance.onError = (error, stack) {
      previousCalled = true;
      return true;
    };

    AilogFlutter.install(logger);

    final handled = ui.PlatformDispatcher.instance.onError!(
      StateError('uncaught async error'),
      StackTrace.current,
    );

    expect(previousCalled, isTrue);
    expect(handled, isTrue);
    expect(sink.events, hasLength(1));
    expect(sink.events.single.level, LogLevel.fatal);
    expect(sink.events.single.tags, contains('uncaught'));
  });
}
