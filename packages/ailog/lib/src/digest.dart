/// Reduces a JSONL log file (potentially hundreds of thousands of lines) into
/// a bounded digest sized for an LLM context window.
///
/// The digest answers the three questions an AI is almost always asked to
/// answer from logs: what broke, how often, and what led up to it — without
/// requiring the whole file to be read first.
library;

import 'dart:convert';

import 'ids.dart';
import 'log_event.dart';
import 'log_level.dart';
import 'normalizer.dart';

/// One group of occurrences sharing an error fingerprint.
///
/// Tracks two different counts, because they answer different questions and
/// conflating them actively misleads:
///
/// * [occurrences] — how many log events carry this fingerprint.
/// * [incidents] — how many *distinct failures* that represents.
///
/// They diverge whenever one failure is logged more than once as it
/// propagates, which is the normal result of idiomatic usage: `span()`
/// records the failure that passed through it, and then the caller catches
/// the same exception at a boundary and logs it again. Both are correct
/// individually; together they double the raw count. Ranking by
/// [occurrences] would then report a bug as twice as frequent as it is, and
/// rank a deep-stack error above a shallower but genuinely more common one.
///
/// [incidents] counts distinct trace ids instead, so one request that failed
/// once counts once no matter how many layers logged it. Untraced events
/// can't be attributed to a request, so each is counted as its own incident
/// — an over-count, but a safe direction, and a reason to use traces.
class ErrorGroup {
  ErrorGroup({required this.fingerprint, required this.first});

  final String fingerprint;
  final LogEvent first;

  /// Raw number of log events with this fingerprint.
  int occurrences = 0;

  DateTime? firstSeen;
  DateTime? lastSeen;
  LogEvent? lastEvent;

  /// Distinct traces this error appeared in. Bounded by [maxRetainedTraceIds]
  /// so a long-running file with many traces can't grow this without limit;
  /// [incidents] stays accurate past that bound via [_untracedIncidents] and
  /// [_distinctTraceCount].
  final Set<String> traceIds = {};
  final Set<String> loggers = {};

  /// How many trace ids are kept as samples. Beyond this, only the count is
  /// retained.
  static const int maxRetainedTraceIds = 32;

  int _distinctTraceCount = 0;
  int _untracedIncidents = 0;

  /// Number of distinct failures, de-duplicating one failure logged at
  /// several layers of the same trace. This is what ranking uses.
  int get incidents => _distinctTraceCount + _untracedIncidents;

  /// The most recent event for this group that carries a causal chain.
  ///
  /// The last event is often the outermost re-log (a bare `catch` at a
  /// boundary), which may have a thinner chain than the innermost one. Prefer
  /// whichever actually has context to show.
  LogEvent? chainSource;

  void add(LogEvent event) {
    occurrences++;
    firstSeen = firstSeen == null || event.time.isBefore(firstSeen!)
        ? event.time
        : firstSeen;
    lastSeen = lastSeen == null || event.time.isAfter(lastSeen!)
        ? event.time
        : lastSeen;
    if (lastEvent == null || event.time.isAfter(lastEvent!.time)) {
      lastEvent = event;
    }

    final traceId = event.traceId;
    if (traceId == null) {
      _untracedIncidents++;
    } else {
      // Count before sampling, so the bound on retained ids doesn't distort
      // the incident count.
      if (!traceIds.contains(traceId) && !_recentOverflow.contains(traceId)) {
        _distinctTraceCount++;
        if (traceIds.length < maxRetainedTraceIds) {
          traceIds.add(traceId);
        } else {
          // Past the sample bound, remember only a bounded window of recent
          // trace ids. The duplicates that matter — one failure logged at
          // several layers — arrive adjacent in time, so a small window
          // catches them; a full set would grow without limit and make the
          // bound above meaningless. Beyond the window `incidents` can
          // over-count, which is the safe direction.
          _recentOverflow.add(traceId);
          if (_recentOverflow.length > _overflowWindow) {
            _recentOverflow.remove(_recentOverflow.first);
          }
        }
      }
    }

    if (event.chain.isNotEmpty &&
        (chainSource == null ||
            event.chain.length > chainSource!.chain.length)) {
      chainSource = event;
    }

    loggers.add(event.logger);
  }

  /// How many trace ids past [maxRetainedTraceIds] are remembered for
  /// de-duplication.
  static const int _overflowWindow = 128;

  /// Recently seen trace ids past the sample bound. Insertion-ordered so the
  /// oldest is evicted first.
  final Set<String> _recentOverflow = <String>{};

  Map<String, Object?> toJson({bool includeChain = true}) => {
        'fingerprint': fingerprint,
        'type': first.error?.type,
        'message': first.error?.message ?? first.message,
        'incidents': incidents,
        'occurrences': occurrences,
        'firstSeen': firstSeen?.toIso8601String(),
        'lastSeen': lastSeen?.toIso8601String(),
        'loggers': loggers.toList()..sort(),
        'sampleTraceIds': traceIds.take(5).toList(),
        'frames': first.error?.frames ?? const [],
        if (includeChain && (chainSource?.chain.isNotEmpty ?? false))
          'lastChain': chainSource!.chain,
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

  /// Sorted by [ErrorGroup.incidents] descending — distinct failures, not raw
  /// log lines. See [ErrorGroup] for why those differ.
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

    buffer.writeln('## Top errors (by distinct failures)');
    buffer.writeln();
    var rank = 1;
    for (final group in errorGroups.take(maxGroups)) {
      final label = group.first.error?.type ??
          '${group.first.level.wireName} in ${group.first.logger}';
      buffer.writeln(
          '### ${rank++}. `$label` (×${group.incidents}, fp:${group.fingerprint})');
      buffer.writeln();
      buffer.writeln(
          '- Message: ${group.first.error?.message ?? group.first.message}');
      buffer.writeln('- Distinct failures: ${group.incidents}');
      // Surfacing both numbers matters: a gap between them means the same
      // failure was logged at several layers, which is worth knowing before
      // concluding anything about how often this actually happens.
      if (group.occurrences != group.incidents) {
        buffer.writeln('- Log events: ${group.occurrences} '
            '(the same failure logged at multiple layers)');
      }
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
      final chain = group.chainSource?.chain ?? const [];
      if (chain.isNotEmpty) {
        buffer.writeln('- Events leading up to it:');
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

    // Group anything at error level or above, not just events carrying an
    // exception. `logger.errorMessage('payment rejected')` is an ordinary
    // thing to write, and grouping only exception-bearing events made those
    // vanish from the digest entirely: the summary would say `error=4` while
    // the body said "No errors recorded."
    if (event.level.severity < LogLevel.error.severity) return;

    final error = event.error;
    final fingerprint = error?.fingerprint ??
        // No stack to normalize, so group by the shape of the message —
        // `order 44 missing` and `order 99 missing` are one problem.
        'msg:${shortHash('${event.logger}|${normalizeMessage(event.message)}')}';

    final group = _groups.putIfAbsent(
      fingerprint,
      () => ErrorGroup(fingerprint: fingerprint, first: event),
    );
    group.add(event);
  }

  Digest build() {
    // Rank by distinct failures, not raw log lines: a bug logged once per
    // request outranks one logged four times within a single request.
    // Occurrences break ties so the ordering stays stable.
    final groups = _groups.values.toList()
      ..sort((a, b) {
        final byIncidents = b.incidents.compareTo(a.incidents);
        if (byIncidents != 0) return byIncidents;
        return b.occurrences.compareTo(a.occurrences);
      });
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
