import '../models/step_journal_entry.dart';
import 'formatting.dart';
import 'step_projection.dart';

/// What one sensor reading works out to for display.
class LiveReading {
  /// Local date the reading belongs to, as `yyyy-MM-dd`.
  final String date;

  /// The day's total as the user should see it, sensor plus manual credits.
  final int displaySteps;

  const LiveReading({required this.date, required this.displaySteps});
}

/// Drives the live display from journalled readings.
///
/// Journalling every reading would be thousands of rows a day and buy
/// nothing: the derived totals only need readings often enough to bound how
/// far a gap can misattribute steps. Between writes the displayed figure is
/// the last derived total plus the steps taken since the last journalled
/// reading, which costs nothing and stays exact.
///
/// A reading is journalled when the interval has elapsed, when the hour
/// turns, or when the date does. The hour and date triggers are what keep
/// the charts and the day boundary honest without sampling faster.
class LiveStepCounter {
  LiveStepCounter(
    this._projection, {
    required double Function() correctionFactor,
    this.interval = const Duration(minutes: 5),
  }) : _correctionFactor = correctionFactor;

  final StepProjection _projection;
  final double Function() _correctionFactor;
  final Duration interval;

  int? _lastJournalledRaw;
  DateTime? _lastJournalledAt;

  /// Today's total as last derived, and the date it belongs to.
  int _derivedTotal = 0;
  String? _derivedDate;

  /// The most recent displayed total, or null if nothing has been recorded.
  int? _lastDisplaySteps;
  int? get lastDisplaySteps => _lastDisplaySteps;

  /// [observedAt] is the sensor's own event time, when there is one — the
  /// moment the counter actually stood at [rawSteps], which for a reading
  /// buffered through a device sleep is not the moment it arrived. Recording
  /// it there is what keeps a night's walking on the night it happened.
  Future<LiveReading> record(
    int rawSteps,
    DateTime now, {
    DateTime? observedAt,
  }) async {
    if (_shouldJournal(now)) {
      await _journal(rawSteps, now, observedAt);
    }

    final since = _lastJournalledRaw == null
        ? 0
        : ((rawSteps - _lastJournalledRaw!) * _correctionFactor()).round();

    final date = dateKey(now);
    // A rollover between journal writes: the derived total belongs to
    // yesterday and says nothing about today.
    final base = _derivedDate == date ? _derivedTotal : 0;
    final display = base + (since > 0 ? since : 0);

    _lastDisplaySteps = display;
    return LiveReading(date: date, displaySteps: display);
  }

  /// Commits the current reading. Called before the service stops, so the
  /// steps since the last write aren't waiting on a timer that never fires.
  Future<void> flush(int rawSteps, DateTime now) => _journal(rawSteps, now, null);

  /// Re-reads the derived total without journalling — for a manual credit,
  /// which changes the day's total without any reading having arrived.
  Future<void> refresh(DateTime now) async {
    await _loadDerived(dateKey(now));
  }

  bool _shouldJournal(DateTime now) {
    final last = _lastJournalledAt;
    if (last == null) return true;
    if (now.difference(last) >= interval) return true;
    // Cheaper than it looks and worth it: an entry on each boundary is what
    // lets the fold attribute a day and an hour exactly.
    return dateKey(last) != dateKey(now) || last.hour != now.hour;
  }

  Future<void> _journal(
    int rawSteps,
    DateTime now,
    DateTime? observedAt,
  ) async {
    await _projection.record(
      StepJournalEntry(at: _recordTime(now, observedAt), rawSteps: rawSteps),
    );
    _lastJournalledRaw = rawSteps;
    // Wall clock, deliberately, even when the entry was filed earlier: this
    // governs how often to journal, which is a question about elapsed real
    // time rather than about when the steps happened.
    _lastJournalledAt = now;
    await _loadDerived(dateKey(now));
  }

  /// The event time when it is usable, otherwise now. Nothing can have been
  /// observed in the future, and [StepProjection] refuses anything that would
  /// land out of order, so this only has to reject the obviously wrong.
  static DateTime _recordTime(DateTime now, DateTime? observedAt) {
    if (observedAt == null || observedAt.isAfter(now)) return now;
    return observedAt;
  }

  Future<void> _loadDerived(String date) async {
    _derivedDate = date;
    _derivedTotal = await _projection.storedTotalFor(date);
  }
}
