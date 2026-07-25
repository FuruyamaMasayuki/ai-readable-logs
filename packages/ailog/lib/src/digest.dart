/// Reduces a JSONL log file (potentially hundreds of thousands of lines) into
/// a bounded digest sized for an LLM context window.
///
/// The digest answers the three questions an AI is almost always asked to
/// answer from logs: what broke, how often, and what led up to it — without
/// requiring the whole file to be read first.
library;

import 'dart:convert';

import 'log_event.dart';
import 'log_level.dart';

/// One group of occurrences sharing an error fingerprint.
class ErrorGroup {
  ErrorGroup({required this.fingerprint, required this.first});

  final String fingerprint;
  final LogEvent first;
  int count = 0;
  DateTime? firstSeen;
  DateTime? lastSeen;
  LogEvent? lastEvent;
  final Set<String> traceIds = {};
  final Set<String> loggers = {};

  void add(LogEvent event) {
    count++;
    firstSeen = firstSeen == null || event.time.isBefore(firstSeen!)
        ? event.time
        : firstSeen;
    lastSeen = lastSeen == null || event.time.isAfter(lastSeen!)
        ? event.time
        : lastSeen;
    if (lastEvent == null || event.time.isAfter(lastEvent!.time)) {
      lastEvent = event;
    }
    if (event.traceId != null) traceIds.add(event.traceId!);
    loggers.add(event.logger);
  }

  Map<String, Object?> toJson({bool includeChain = true}) => {
        'fingerprint': fingerprint,
        'type': first.error?.type,
        'message': first.error?.message ?? first.message,
        'count': count,
        'firstSeen': firstSeen?.toIso8601String(),
        'lastSeen': lastSeen?.toIso8601String(),
        'loggers': loggers.toList()..sort(),
        'sampleTraceIds': traceIds.take(5).toList(),
        'frames': first.error?.frames ?? const [],
        if (includeChain && (lastEvent?.chain.isNotEmpty ?? false))
          'lastChain': lastEvent!.chain,
      };
}

/// Aggregated view of one log file (or a time-bounded slice of it).
class Digest {
  Digest({
    required this.totalEvents,
    required this.levelCounts,
    required this.errorGroups,
    required this.loggers,
    required this.timeRange,
    required this.droppedEvents,
  });

  final int totalEvents;
  final Map<LogLevel, int> levelCounts;

  /// Sorted by [ErrorGroup.count] descending.
  final List<ErrorGroup> errorGroups;
  final Set<String> loggers;
  final (DateTime?, DateTime?) timeRange;

  /// Events skipped because they failed to parse (header lines, truncated
  /// writes). Reported so the digest never silently looks complete.
  final int droppedEvents;

  Map<String, Object?> toJson({int maxGroups = 20}) => {
        'summary': {
          'totalEvents': totalEvents,
          'droppedEvents': droppedEvents,
          'byLevel': {
            for (final e in levelCounts.entries) e.key.wireName: e.value
          },
          'loggers': loggers.toList()..sort(),
          'from': timeRange.$1?.toIso8601String(),
          'to': timeRange.$2?.toIso8601String(),
          'errorGroupCount': errorGroups.length,
        },
        'topErrors': [
          for (final group in errorGroups.take(maxGroups)) group.toJson(),
        ],
        if (errorGroups.length > maxGroups)
          'truncatedGroups': errorGroups.length - maxGroups,
      };

  /// Renders the digest as Markdown, the form most useful when pasting
  /// straight into a chat with an AI assistant.
  String toMarkdown({int maxGroups = 20}) {
    final buffer = StringBuffer();
    buffer.writeln('# Log digest');
    buffer.writeln();
    buffer.writeln('- Events: $totalEvents'
        '${droppedEvents > 0 ? ' ($droppedEvents unparsed)' : ''}');
    if (timeRange.$1 != null && timeRange.$2 != null) {
      buffer.writeln(
          '- Range: ${timeRange.$1!.toIso8601String()} → ${timeRange.$2!.toIso8601String()}');
    }
    final levelSummary = levelCounts.entries
        .where((e) => e.value > 0)
        .map((e) => '${e.key.wireName}=${e.value}')
        .join(', ');
    buffer.writeln('- Levels: $levelSummary');
    buffer.writeln('- Loggers: ${(loggers.toList()..sort()).join(', ')}');
    buffer.writeln();

    if (errorGroups.isEmpty) {
      buffer.writeln('No errors recorded.');
      return buffer.toString();
    }

    buffer.writeln('## Top errors (by occurrence count)');
    buffer.writeln();
    var rank = 1;
    for (final group in errorGroups.take(maxGroups)) {
      buffer.writeln('### ${rank++}. `${group.first.error?.type ?? 'error'}` '
          '(×${group.count}, fp:${group.fingerprint})');
      buffer.writeln();
      buffer.writeln(
          '- Message: ${group.first.error?.message ?? group.first.message}');
      buffer.writeln('- Loggers: ${group.loggers.join(', ')}');
      buffer.writeln('- First seen: ${group.firstSeen?.toIso8601String()}');
      buffer.writeln('- Last seen: ${group.lastSeen?.toIso8601String()}');
      final frames = group.first.error?.frames ?? const [];
      if (frames.isNotEmpty) {
        buffer.writeln('- Top frames:');
        for (final frame in frames.take(5)) {
          buffer.writeln('  - `$frame`');
        }
      }
      final chain = group.lastEvent?.chain ?? const [];
      if (chain.isNotEmpty) {
        buffer.writeln('- Events leading up to the last occurrence:');
        for (final entry in chain) {
          buffer.writeln(
              '  - `${entry['dt']}ms` [${entry['lvl']}] ${entry['msg']}');
        }
      }
      buffer.writeln();
    }
    if (errorGroups.length > maxGroups) {
      buffer.writeln(
          '_…and ${errorGroups.length - maxGroups} more error group(s), '
          'omitted for brevity._');
    }
    return buffer.toString();
  }
}

/// Streams a JSONL file and builds a [Digest] without holding every event in
/// memory — only the aggregates and, per error group, the first/last sample.
class DigestBuilder {
  DigestBuilder();

  int _total = 0;
  int _dropped = 0;
  final Map<LogLevel, int> _levelCounts = {
    for (final l in LogLevel.values) l: 0
  };
  final Map<String, ErrorGroup> _groups = {};
  final Set<String> _loggers = {};
  DateTime? _from;
  DateTime? _to;

  /// Feeds one raw JSONL line. Header lines and unparsable lines are counted
  /// in [Digest.droppedEvents] and otherwise skipped.
  void addLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;

    Map<String, Object?>? json;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) json = decoded.cast<String, Object?>();
    } on FormatException {
      json = null;
    }

    if (json == null || json['_hdr'] == true) {
      if (json?['_hdr'] != true) _dropped++;
      return;
    }

    final event = LogEvent.fromJson(json);
    if (event == null) {
      _dropped++;
      return;
    }
    addEvent(event);
  }

  void addEvent(LogEvent event) {
    _total++;
    _levelCounts[event.level] = (_levelCounts[event.level] ?? 0) + 1;
    _loggers.add(event.logger);
    _from = _from == null || event.time.isBefore(_from!) ? event.time : _from;
    _to = _to == null || event.time.isAfter(_to!) ? event.time : _to;

    final error = event.error;
    if (error != null) {
      final group = _groups.putIfAbsent(
        error.fingerprint,
        () => ErrorGroup(fingerprint: error.fingerprint, first: event),
      );
      group.add(event);
    }
  }

  Digest build() {
    final groups = _groups.values.toList()
      ..sort((a, b) => b.count.compareTo(a.count));
    return Digest(
      totalEvents: _total,
      levelCounts: _levelCounts,
      errorGroups: groups,
      loggers: _loggers,
      timeRange: (_from, _to),
      droppedEvents: _dropped,
    );
  }
}
