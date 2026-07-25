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
        'firstSeen': firstSeen?.toUtc().toIso8601String(),
        'lastSeen': lastSeen?.toUtc().toIso8601String(),
        'loggers': loggers.toList()..sort(),
        'sampleTraceIds': traceIds.take(5).toList(),
        'frames': first.error?.frames ?? const [],
        if (includeChain && (chainSource?.chain.isNotEmpty ?? false))
          'lastChain': chainSource!.chain,
      };
}

/// Renders a context map as compact `key=value` pairs.
String _renderContext(Map<String, Object?> context) =>
    context.entries.map((e) => '${e.key}=${e.value}').join(' ');

/// How many times one normalized message shape occurred.
///
/// This exists because of a measured failure. The same connection-pool leak
/// was handed to two blind diagnosis runs: one got the raw 160-line log, the
/// other this digest. The raw log won outright — root cause identified with
/// high confidence — while the digest run concluded "I cannot tell a leak
/// from an ordering bug."
///
/// The proof was `40 lease acquired` against `18 lease released`. A digest
/// that keeps only errors and their causal chains destroys that, because the
/// evidence is an *absence* spread across the successful requests, and
/// nothing about a successful request looks worth keeping. Filtering to
/// failing traces would have destroyed it too: the leaked leases belong to
/// the requests that succeeded.
///
/// Counting every message shape costs one line per distinct shape — a
/// rounding error next to the events themselves — and restores exactly the
/// kind of evidence summarization is worst at preserving.
class MessageShape {
  MessageShape(
      {required this.logger, required this.shape, required this.level});

  final String logger;

  /// The message with numbers, ids, paths and quoted strings replaced by
  /// placeholders, so `GET /product/38` and `GET /product/39` are one shape.
  final String shape;

  /// Highest level seen for this shape.
  LogLevel level;
  int count = 0;

  Map<String, Object?> toJson() => {
        'logger': logger,
        'shape': shape,
        'level': level.wireName,
        'count': count,
      };
}

/// Range of a numeric context field across the whole log.
///
/// A counter that climbs to `max=22` against a configured ceiling of 20 is a
/// diagnosis by itself, and it is invisible in any per-error view.
class NumericField {
  NumericField(this.key);

  final String key;
  num? min;
  num? max;
  num? last;
  int count = 0;

  void add(num value) {
    count++;
    min = min == null || value < min! ? value : min;
    max = max == null || value > max! ? value : max;
    last = value;
  }

  Map<String, Object?> toJson() =>
      {'key': key, 'min': min, 'max': max, 'last': last, 'n': count};
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
    this.messageShapes = const [],
    this.numericFields = const [],
    this.unshapedEvents = 0,
    this.breadcrumbOnlyLoggers = const {},
  });

  final int totalEvents;
  final Map<LogLevel, int> levelCounts;

  /// Every distinct message shape with its count, most frequent first.
  ///
  /// See [MessageShape] — this section is what lets a reader spot a missing
  /// counterpart (acquires without releases, opens without closes, retries
  /// without successes) that no per-error view can show.
  final List<MessageShape> messageShapes;

  /// Ranges of numeric context fields across the whole log.
  final List<NumericField> numericFields;

  /// Events whose shape arrived after [DigestBuilder.maxShapes] distinct
  /// shapes were already tracked, and so are missing from [messageShapes].
  final int unshapedEvents;

  /// Loggers that appear only inside causal chains, never as their own line.
  ///
  /// This is the signature of a level threshold set above the level those
  /// events are logged at: the breadcrumbs survive, the lines don't. It is
  /// worth saying out loud, because a reader who sees `[debug]` entries in a
  /// chain while the summary reports no debug events concludes — reasonably
  /// — that the digest contradicts itself, and starts distrusting all of it.
  final Set<String> breadcrumbOnlyLoggers;

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
          'from': timeRange.$1?.toUtc().toIso8601String(),
          'to': timeRange.$2?.toUtc().toIso8601String(),
          'errorGroupCount': errorGroups.length,
        },
        'topErrors': [
          for (final group in errorGroups.take(maxGroups)) group.toJson(),
        ],
        if (errorGroups.length > maxGroups)
          'truncatedGroups': errorGroups.length - maxGroups,
        if (messageShapes.isNotEmpty)
          'messageShapes': [for (final s in messageShapes) s.toJson()],
        if (numericFields.isNotEmpty)
          'numericFields': [for (final f in numericFields) f.toJson()],
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
      buffer.writeln('- Range: ${timeRange.$1!.toUtc().toIso8601String()} → '
          '${timeRange.$2!.toUtc().toIso8601String()}');
    }
    final levelSummary = levelCounts.entries
        .where((e) => e.value > 0)
        .map((e) => '${e.key.wireName}=${e.value}')
        .join(', ');
    buffer.writeln('- Levels: $levelSummary');
    buffer.writeln('- Loggers: ${(loggers.toList()..sort()).join(', ')}');
    if (breadcrumbOnlyLoggers.isNotEmpty) {
      final names = (breadcrumbOnlyLoggers.toList()..sort()).join(', ');
      buffer.writeln('- Not in this file: $names — these appear only inside '
          'causal chains below, because the level threshold kept their own '
          'lines out. Their counts are therefore incomplete here; lower the '
          "logger's minimumLevel to capture them in full.");
    }
    buffer.writeln();

    if (errorGroups.isEmpty) {
      buffer.writeln('No errors recorded.');
      _writeAggregates(buffer);
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
      buffer.writeln(
          '- First seen: ${group.firstSeen?.toUtc().toIso8601String()}');
      buffer
          .writeln('- Last seen: ${group.lastSeen?.toUtc().toIso8601String()}');
      // The failing event's own context is often the direct evidence — the
      // order id, the endpoint, the retry count. Dropping it forces whoever
      // reads the digest back to the raw file for the one thing they needed.
      final failingContext = group.first.context;
      if (failingContext.isNotEmpty) {
        // Say plainly that this is one sample, not a property of the group.
        // A blind reader took `requestId=req-38 endpoint=/product/38` on a
        // group of three as evidence that all three hit the same endpoint,
        // and floated "hot key on one endpoint" as a rival explanation that
        // the digest had accidentally manufactured.
        final label = group.incidents > 1
            ? 'Context (first of ${group.incidents})'
            : 'Context';
        buffer.writeln('- $label: ${_renderContext(failingContext)}');
        final lastContext = group.lastEvent?.context ?? const {};
        if (group.incidents > 1 &&
            lastContext.isNotEmpty &&
            !_sameContext(failingContext, lastContext)) {
          buffer.writeln('- Context (most recent): '
              '${_renderContext(lastContext)}');
        }
      }
      final frames = group.first.error?.frames ?? const [];
      if (frames.isNotEmpty) {
        buffer.writeln('- Top frames:');
        for (final frame in frames.take(5)) {
          buffer.writeln('  - `$frame`');
        }
      }
      final chain = group.chainSource?.chain ?? const [];
      if (chain.isNotEmpty) {
        // Naming these as breadcrumbs resolves what otherwise reads as a
        // contradiction: a reader saw `Levels: info=99, error=3` above and a
        // `[debug]` line here, and reasonably concluded the digest was
        // inconsistent with itself. Breadcrumbs are captured below the
        // emitted threshold on purpose, so they legitimately have no
        // corresponding line of their own.
        buffer.writeln('- Events leading up to it (breadcrumbs — recorded '
            'below the emitted level threshold, so they may have no line of '
            'their own above):');
        for (final entry in chain) {
          // Include each breadcrumb's context. It is routinely the decisive
          // detail — `leased=20 max=20` two lines before a timeout names the
          // cause outright, and rendering only the message throws that away.
          final crumbContext = entry['ctx'];
          final rendered = crumbContext is Map && crumbContext.isNotEmpty
              ? ' ${_renderContext(crumbContext.cast<String, Object?>())}'
              : '';
          buffer.writeln(
              '  - `${entry['dt']}ms` [${entry['lvl']}] ${entry['msg']}$rendered');
        }
      }
      buffer.writeln();
    }
    if (errorGroups.length > maxGroups) {
      buffer.writeln(
          '_…and ${errorGroups.length - maxGroups} more error group(s), '
          'omitted for brevity._');
    }
    _writeAggregates(buffer);
    return buffer.toString();
  }

  /// Writes the whole-log aggregates: what happened how often, and how the
  /// numbers moved. See [MessageShape] for why these earn their space.
  void _writeAggregates(StringBuffer buffer, {int maxShapes = 60}) {
    if (messageShapes.isEmpty && numericFields.isEmpty) return;

    if (messageShapes.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('## Event mix (all $totalEvents events)');
      buffer.writeln();
      buffer.writeln('Every distinct message shape, with numbers and ids '
          'replaced by placeholders. Counts that should match and do not — '
          'acquires against releases, opens against closes, starts against '
          'completions — are frequently the whole diagnosis, and are visible '
          'nowhere else in this file.');
      buffer.writeln();
      for (final shape in messageShapes.take(maxShapes)) {
        buffer.writeln('- `${shape.logger}` [${shape.level.wireName}] '
            '`${shape.shape}` ×${shape.count}');
      }
      if (messageShapes.length > maxShapes) {
        buffer.writeln('- _…and ${messageShapes.length - maxShapes} rarer '
            'shape(s), omitted._');
      }
      if (unshapedEvents > 0) {
        buffer.writeln('- _$unshapedEvents event(s) are missing from these '
            'counts: the log had more distinct shapes than the builder '
            'tracks, so the totals above are lower bounds._');
      }
    }

    if (numericFields.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('## Numeric context fields');
      buffer.writeln();
      buffer.writeln('Range of every numeric value logged in `ctx`, across '
          'all events. A counter that ends far from where it started, or '
          'that exceeds a limit logged beside it, is a lead.');
      buffer.writeln();
      for (final field in numericFields) {
        buffer.writeln('- `${field.key}`: min=${field.min} max=${field.max} '
            'last=${field.last} (n=${field.count})');
      }
    }
  }
}

/// Shallow equality for two context maps.
bool _sameContext(Map<String, Object?> a, Map<String, Object?> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) return false;
  }
  return true;
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

  /// Distinct message shapes tracked. Past this, new shapes are counted in
  /// [_unshapedEvents] rather than growing the map without bound — a log
  /// where every line is unique would otherwise be held entirely in memory,
  /// defeating the point of streaming.
  static const int maxShapes = 500;

  /// Distinct numeric context keys tracked.
  static const int maxNumericFields = 64;

  final Map<String, MessageShape> _shapes = {};
  final Map<String, NumericField> _numeric = {};
  final Set<String> _breadcrumbLoggers = {};
  int _unshapedEvents = 0;

  void addEvent(LogEvent event) {
    _total++;
    _levelCounts[event.level] = (_levelCounts[event.level] ?? 0) + 1;
    _loggers.add(event.logger);
    _from = _from == null || event.time.isBefore(_from!) ? event.time : _from;
    _to = _to == null || event.time.isAfter(_to!) ? event.time : _to;
    _recordShape(event);
    _recordNumericContext(event);
    for (final crumb in event.chain) {
      final logger = crumb['lg'];
      if (logger is String) _breadcrumbLoggers.add(logger);
    }

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

  void _recordShape(LogEvent event) {
    final shape = normalizeMessage(event.message);
    if (shape.isEmpty) return;
    final key = '${event.logger}|$shape';
    final existing = _shapes[key];
    if (existing != null) {
      existing.count++;
      if (event.level.severity > existing.level.severity) {
        existing.level = event.level;
      }
      return;
    }
    if (_shapes.length >= maxShapes) {
      _unshapedEvents++;
      return;
    }
    _shapes[key] = MessageShape(
      logger: event.logger,
      shape: shape,
      level: event.level,
    )..count = 1;
  }

  void _recordNumericContext(LogEvent event) {
    if (event.context.isEmpty) return;
    for (final entry in event.context.entries) {
      final value = entry.value;
      // Booleans are `num`-adjacent in spirit but meaningless as a range,
      // and redacted values are strings by the time they get here.
      if (value is! num) continue;
      final existing = _numeric[entry.key];
      if (existing != null) {
        existing.add(value);
      } else if (_numeric.length < maxNumericFields) {
        _numeric[entry.key] = NumericField(entry.key)..add(value);
      }
    }
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
    final shapes = _shapes.values.toList()
      ..sort((a, b) {
        final byCount = b.count.compareTo(a.count);
        if (byCount != 0) return byCount;
        // Stable, readable ordering for equal counts.
        final byLogger = a.logger.compareTo(b.logger);
        return byLogger != 0 ? byLogger : a.shape.compareTo(b.shape);
      });
    final numeric = _numeric.values.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return Digest(
      totalEvents: _total,
      levelCounts: _levelCounts,
      errorGroups: groups,
      loggers: _loggers,
      timeRange: (_from, _to),
      droppedEvents: _dropped,
      messageShapes: shapes,
      numericFields: numeric,
      unshapedEvents: _unshapedEvents,
      breadcrumbOnlyLoggers: _breadcrumbLoggers.difference(_loggers),
    );
  }
}
