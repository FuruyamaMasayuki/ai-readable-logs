import 'dart:async';

import 'package:ailog_flutter/ailog_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('logs push and pop as info events with route names',
      (tester) async {
    final sink = MemorySink();
    final logger = Logger.forTesting(sink: sink);

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [AilogNavigatorObserver(logger)],
        home: const _HomePage(),
      ),
    );

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: '/details'),
          builder: (_) => const Scaffold(body: Text('details')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    navigator.pop();
    await tester.pumpAndSettle();

    final messages = sink.events.map((e) => e.message).toList();
    expect(messages, contains('route pushed'));
    expect(messages, contains('route popped'));

    // The initial MaterialApp route ('/') also fires 'route pushed', so
    // find the one we pushed explicitly rather than assuming there is only
    // one.
    final pushed = sink.events.firstWhere(
      (e) => e.message == 'route pushed' && e.context['route'] == '/details',
    );
    expect(pushed.context['from'], '/');
    expect(pushed.tags, contains('navigation'));
  });
}

class _HomePage extends StatelessWidget {
  const _HomePage();

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('home'));
}
