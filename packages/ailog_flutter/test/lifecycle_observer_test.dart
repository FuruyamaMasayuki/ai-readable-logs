import 'package:ailog_flutter/ailog_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late MemorySink sink;
  late Logger logger;
  late AilogLifecycleObserver observer;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sink = MemorySink();
    logger = Logger.create(sink: sink);
    observer = AilogLifecycleObserver(logger)..install();
  });

  tearDown(() => observer.dispose());

  void send(AppLifecycleState state) =>
      observer.didChangeAppLifecycleState(state);

  test('records a transition with both ends of it', () {
    send(AppLifecycleState.paused);

    final event = sink.events.single;
    expect(event.message, '▸ app paused');
    expect(event.logger, 'lifecycle');
    expect(event.context['to'], 'paused');
    expect(event.tags, containsAll(<String>['interaction', 'lifecycle']));
  });

  test('the second transition names where it came from', () {
    // `paused → resumed` and `hidden → resumed` mean different things on
    // iOS, and which one preceded a crash is the question being asked.
    send(AppLifecycleState.paused);
    send(AppLifecycleState.resumed);

    final resumed = sink.events.last;
    expect(resumed.context['from'], 'paused');
    expect(resumed.context['to'], 'resumed');
  });

  test('a repeated state is not logged twice', () {
    // The platform re-delivers the current state in some situations; a log
    // that repeats it is noise, and this package is built around not
    // wasting a context window.
    send(AppLifecycleState.resumed);
    send(AppLifecycleState.resumed);
    send(AppLifecycleState.resumed);

    expect(sink.events, hasLength(1));
  });

  test('defaults to trace, so it stays out of a production file', () {
    send(AppLifecycleState.inactive);

    expect(sink.events.single.level, LogLevel.trace);
  });

  test('level is configurable for apps that want these written', () {
    final loud = MemorySink();
    final observer2 = AilogLifecycleObserver(
      Logger.create(sink: loud),
      level: LogLevel.info,
    );
    addTearDown(observer2.dispose);

    observer2.didChangeAppLifecycleState(AppLifecycleState.detached);

    expect(loud.events.single.level, LogLevel.info);
  });

  test('install() twice registers only one observer', () {
    observer.install();
    observer.install();

    // Delivered once by the binding per real transition; the guard is about
    // not receiving it N times after N installs.
    send(AppLifecycleState.paused);
    expect(sink.events, hasLength(1));
  });

  test('dispose() is safe twice, and before install', () {
    expect(() {
      observer.dispose();
      observer.dispose();
      AilogLifecycleObserver(logger).dispose();
    }, returnsNormally);
  });

  test('transitions land in a later error causal chain', () {
    // The whole point: at trace level these are invisible in the file but
    // present in the chain of whatever fails next.
    final chained = MemorySink();
    final appLogger = Logger.create(sink: chained, minimumLevel: LogLevel.info);
    final lifecycle = AilogLifecycleObserver(appLogger)..install();
    addTearDown(lifecycle.dispose);

    runWithScope(appLogger.startTrace(), () {
      lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
      lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
      appLogger.error(StateError('boom'), StackTrace.current);
    });

    final error = chained.events.single;
    expect(error.chain.map((c) => c['msg']),
        containsAll(<String>['▸ app paused', '▸ app resumed']));
  });
}
