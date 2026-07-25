/// Turning captured events into something worth an AI's context window.
///
/// Two problems, one answer:
///
/// * **Getting the log as a string.** Writing to a file and reading it back
///   is the wrong shape for "attach logs to this bug report", "show me the
///   log in the app", or "send the last minute to the assistant". Everything
///   here returns a [String].
/// * **Not feeding an AI junk.** A log is mostly uneventful. Paying for
///   40,000 healthy lines to reach three broken ones is a bad trade, and a
///   long enough log simply will not fit.
///
/// The filters below shrink the second problem, but they are deliberately
/// conservative, because over-filtering is the more dangerous failure. That
/// is not a hunch: the same connection-pool leak was handed to two blind
/// diagnosis runs, one with the raw log and one with a digest. The raw log
/// won — the digest had thrown away the successful requests, and the proof of
/// the leak was that those requests acquired a connection and never released
/// it. Filtering to the *failing* traces would have destroyed the same
/// evidence, because the leaked leases belonged to requests that succeeded.
///
/// So: prefer [LogFilter.aroundErrors] and [LogFilter.collapseRepeats], which
/// drop bulk while keeping the shape of what happened, over
/// [LogFilter.onlyFailedTraces], which is cheap and occasionally blinding.
/// Whatever is dropped is reported in [LogSelection.droppedBy] and stated in
/// the rendered output, so the result never looks more complete than it is.
library;

import 'dart:convert';

import 'digest.dart';
import 'log_event.dart';
import 'log_level.dart';
import 'normalizer.dart';

/// Chooses which events are worth sending to an AI.
///
/// Filters compose; they are applied in the order documented on each field.
class LogFilter {
  const LogFilter({
    this.minimumLevel = LogLevel.trace,
    this.onlyFailedTraces = false,
    this.aroundErrors,
    this.collapseRepeats = false,
    this.loggers,
    this.maxEvents,
    this.since,
  });

  /// Keeps everything. The default when you just want the text.
  static const LogFilter none = LogFilter();

  /// A good default for handing a long log to an AI: collapse repeated
  /// noise, then keep a window of context around anything that failed.
  ///
  /// Preserves the [Digest] aggregates regardless, so whole-log counts
  /// survive even when most events do not.
  static const LogFilter forAi = LogFilter(
    collapseRepeats: true,
    aroundErrors: 30,
  );

  /// Drops events below this level. Applied first.
  final LogLevel minimumLevel;

  /// Keeps only the loggers named here. Null keeps all of them.
  final Set<String>? loggers;

  /// Drops events older than this.
  final DateTime? since;

  /// Collapses runs of the same logger, level and message *shape* into a
  /// single event carrying `repeated` in its context.
  ///
  /// This is the safest large win available: a poll loop or a rebuilding
  /// widget can be most of a log file, and the tenth identical line teaches
  /// an AI nothing the first did not. Only consecutive runs collapse, so the
  /// interleaving with everything else is preserved.
  final bool collapseRepeats;

  /// Keeps only events within this many events of an error-or-worse one.
  ///
  /// Preferred over [onlyFailedTraces] because it needs no trace ids and
  /// keeps the events immediately *before* a failure — which is usually
  /// where the cause is — including ones belonging to other traces.
  final int? aroundErrors;

  /// Keeps only events whose trace produced an error, plus untraced errors.
  ///
  /// The most aggressive filter here, and the one most likely to delete the
  /// answer: a failure caused by unrelated successful work leaves no trace of
  /// itself in the failing request. Use when volume leaves no choice, and
  /// read [LogSelection.droppedBy] before trusting the result.
  final bool onlyFailedTraces;

  /// Hard cap on the number of events kept, applied last. The most recent
  /// events are kept, since they are nearest the failure being investigated.
  final int? maxEvents;

  /// Applies this filter, reporting what it removed and why.
  LogSelection apply(Iterable<LogEvent> events) {
    final input = events.toList();
    final dropped = <String, int>{};
    void drop(String reason, int count) {
      if (count > 0) dropped[reason] = (dropped[reason] ?? 0) + count;
    }

    var kept = input;

    if (minimumLevel != LogLevel.trace) {
      final next = kept.where((e) => e.level.passes(minimumLevel)).toList();
      drop('belowLevel', kept.length - next.length);
      kept = next;
    }

    final loggerFilter = loggers;
    if (loggerFilter != null) {
      final next = kept.where((e) => loggerFilter.contains(e.logger)).toList();
      drop('otherLogger', kept.length - next.length);
      kept = next;
    }

    final cutoff = since;
    if (cutoff != null) {
      final next = kept.where((e) => !e.time.isBefore(cutoff)).toList();
      drop('tooOld', kept.length - next.length);
      kept = next;
    }

    if (collapseRepeats) {
      final next = _collapse(kept);
      drop('repeated', kept.length - next.length);
      kept = next;
    }

    if (onlyFailedTraces) {
      final next = _failedTracesOnly(kept);
      drop('healthyTrace', kept.length - next.length);
      kept = next;
    }

    final window = aroundErrors;
    if (window != null) {
      final next = _window(kept, window);
      drop('farFromError', kept.length - next.length);
      kept = next;
    }

    final cap = maxEvents;
    if (cap != null && kept.length > cap) {
      drop('overCap', kept.length - cap);
      kept = kept.sublist(kept.length - cap);
    }

    return LogSelection(
      events: kept,
      inputCount: input.length,
      droppedBy: dropped,
      // Aggregates are computed over the *input*, not the survivors. This is
      // the point: `40 acquired / 18 released` stays true and stays visible
      // even after the 22 successful requests have been filtered away.
      digest: buildDigest(input),
    );
  }

  static bool _isErrorish(LogEvent event) =>
      event.level.severity >= LogLevel.error.severity;

  static List<LogEvent> _collapse(List<LogEvent> events) {
    final result = <LogEvent>[];
    var runLength = 0;
    String? runKey;
    LogEvent? runFirst;

    void flush() {
      final first = runFirst;
      if (first == null) return;
      if (runLength <= 1) {
        result.add(first);
      } else {
        // The first of the run is kept rather than the last: its context and
        // stack are the ones that were captured before whatever went wrong
        // started repeating.
        result.add(LogEvent(
          time: first.time,
          level: first.level,
          message: first.message,
          logger: first.logger,
          sessionId: first.sessionId,
          sequence: first.sequence,
          traceId: first.traceId,
          spanId: first.spanId,
          parentSpanId: first.parentSpanId,
          context: {...first.context, 'repeated': runLength},
          tags: [...first.tags, 'collapsed'],
          error: first.error,
          durationMs: first.durationMs,
          chain: first.chain,
        ));
      }
      runFirst = null;
      runLength = 0;
      runKey = null;
    }

    for (final event in events) {
      final key = '${event.logger}|${event.level.wireName}|'
          '${normalizeMessage(event.message)}';
      if (key == runKey) {
        runLength++;
        continue;
      }
      flush();
      runKey = key;
      runFirst = event;
      runLength = 1;
    }
    flush();
    return result;
  }

  static List<LogEvent> _failedTracesOnly(List<LogEvent> events) {
    final failed = <String>{};
    for (final event in events) {
      final traceId = event.traceId;
      if (traceId != null && _isErrorish(event)) failed.add(traceId);
    }
    return events.where((e) {
      final traceId = e.traceId;
      // An untraced error can't be attributed, so it is kept rather than
      // silently dropped — losing an error is never the safe direction.
      if (traceId == null) return _isErrorish(e);
      return failed.contains(traceId);
    }).toList();
  }

  static List<LogEvent> _window(List<LogEvent> events, int radius) {
    if (radius < 0) return events;
    final keep = List<bool>.filled(events.length, false);
    var anyError = false;
    for (var i = 0; i < events.length; i++) {
      if (!_isErrorish(events[i])) continue;
      anyError = true;
      final from = (i - radius).clamp(0, events.length - 1);
      final to = (i + radius).clamp(0, events.length - 1);
      for (var j = from; j <= to; j++) {
        keep[j] = true;
      }
    }
    // With nothing to centre a window on, the filter has no opinion. Keeping
    // everything beats returning an empty log to someone investigating a
    // problem that did not surface as an error.
    if (!anyError) return events;
    return [
      for (var i = 0; i < events.length; i++)
        if (keep[i]) events[i],
    ];
  }
}

/// The result of applying a [LogFilter]: the surviving events, what was
/// removed, and the aggregates computed over everything before filtering.
class LogSelection {
  LogSelection({
    required this.events,
    required this.inputCount,
    required this.droppedBy,
    required this.digest,
  });

  final List<LogEvent> events;

  /// How many events went in, before any filtering.
  final int inputCount;

  /// Reason → number of events removed for that reason.
  final Map<String, int> droppedBy;

  /// Aggregates over the unfiltered input. See [LogFilter.apply].
  final Digest digest;

  int get droppedCount => inputCount - events.length;

  /// The events as JSONL — byte-identical in form to what [JsonlFileSink]
  /// writes, so anything that reads the file reads this too.
  ///
  /// [includeHeader] prepends the schema legend, which makes the string
  /// self-describing and is worth its ~400 bytes for any recipient that has
  /// not seen this format before.
  String toJsonl({bool includeHeader = true, bool includeFilterNote = true}) {
    final buffer = StringBuffer();
    if (includeHeader) {
      buffer.writeln(jsonEncode({
        '_hdr': true,
        'schema': aiLogSchemaVersion,
        'generator': 'ailog',
        'legend': schemaLegend(),
      }));
    }
    // A filtered log that does not say it was filtered invites exactly the
    // wrong conclusion — "there is no release call" reads as a bug when the
    // release calls were simply removed on the way out.
    if (includeFilterNote && droppedCount > 0) {
      buffer.writeln(jsonEncode({
        '_hdr': true,
        'note': 'filtered: $droppedCount of $inputCount events removed before '
            'this listing. Counts under _mix are over all $inputCount.',
        'droppedBy': droppedBy,
        '_mix': [for (final s in digest.messageShapes.take(60)) s.toJson()],
      }));
    }
    for (final event in events) {
      buffer.writeln(jsonEncode(event.toJson()));
    }
    return buffer.toString();
  }

  /// The digest as Markdown, with a note about what filtering removed.
  String toMarkdown({int maxGroups = 20}) {
    final buffer = StringBuffer(digest.toMarkdown(maxGroups: maxGroups));
    if (droppedCount > 0) {
      buffer.writeln();
      buffer.writeln('---');
      buffer.writeln();
      buffer.writeln('_Filtered: $droppedCount of $inputCount events were '
          'removed before listing (${_renderDropped()}). The counts above '
          'cover all $inputCount._');
    }
    return buffer.toString();
  }

  /// Digest plus the surviving raw events — the form to reach for when an AI
  /// is expected to actually diagnose something rather than triage it.
  ///
  /// The digest alone measurably underperformed the raw log on a real root
  /// cause; the raw log alone does not scale. This is both.
  String toReport({int maxGroups = 20, bool includeEvents = true}) {
    final buffer = StringBuffer(toMarkdown(maxGroups: maxGroups));
    if (includeEvents && events.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('## Events (${events.length} kept, JSONL)');
      buffer.writeln();
      buffer.writeln('```jsonl');
      buffer.write(toJsonl(includeHeader: false, includeFilterNote: false));
      buffer.writeln('```');
    }
    return buffer.toString();
  }

  String _renderDropped() =>
      droppedBy.entries.map((e) => '${e.key}=${e.value}').join(', ');
}

/// Builds a [Digest] straight from in-memory events.
Digest buildDigest(Iterable<LogEvent> events) {
  final builder = DigestBuilder();
  for (final event in events) {
    builder.addEvent(event);
  }
  return builder.build();
}

/// Builds a [Digest] from raw JSONL text, e.g. a log file already read in.
Digest digestFromJsonl(String jsonl) {
  final builder = DigestBuilder();
  for (final line in const LineSplitter().convert(jsonl)) {
    builder.addLine(line);
  }
  return builder.build();
}
