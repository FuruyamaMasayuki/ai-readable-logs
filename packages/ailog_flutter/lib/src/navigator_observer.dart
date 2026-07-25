/// Turns Flutter navigation into structured, correlated log events.
///
/// Reproducing a UI bug from logs almost always starts with "what screen was
/// the user on". Recording the route timeline as ordinary `info` events —
/// tagged so they are easy to filter, and inside the same trace as everything
/// else the app logs — means that timeline is already in the log the AI
/// analyzes, with no separate breadcrumb system to wire up.
library;

import 'package:ailog/ailog.dart';
import 'package:flutter/widgets.dart';

/// A [NavigatorObserver] that logs push/pop/remove/replace as `info` events.
class AilogNavigatorObserver extends NavigatorObserver {
  AilogNavigatorObserver(Logger logger) : _logger = logger.child('navigation');

  final Logger _logger;

  String _nameOf(Route<dynamic>? route) =>
      route?.settings.name ?? route?.runtimeType.toString() ?? 'unknown';

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _logger.info(
      'route pushed',
      context: {'route': _nameOf(route), 'from': _nameOf(previousRoute)},
      tags: const ['navigation'],
    );
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _logger.info(
      'route popped',
      context: {'route': _nameOf(route), 'to': _nameOf(previousRoute)},
      tags: const ['navigation'],
    );
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _logger.info(
      'route removed',
      context: {'route': _nameOf(route), 'to': _nameOf(previousRoute)},
      tags: const ['navigation'],
    );
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _logger.info(
      'route replaced',
      context: {'route': _nameOf(newRoute), 'replaced': _nameOf(oldRoute)},
      tags: const ['navigation'],
    );
  }
}
