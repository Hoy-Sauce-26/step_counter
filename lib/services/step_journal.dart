import '../models/step_journal_entry.dart';
import 'formatting.dart';

/// Sensor-derived totals produced by folding the journal. Manual credits are
/// deliberately absent — nobody walked those, and they are added on top when
/// a day's displayed figure is assembled.
class StepTotals {
  /// `yyyy-MM-dd` to steps.
  final Map<String, int> daily;

  /// (`yyyy-MM-dd`, hour) to steps.
  final Map<(String, int), int> hourly;

  const StepTotals({required this.daily, required this.hourly});

  static const empty = StepTotals(daily: {}, hourly: {});
}

/// Derives step totals from journalled counter readings.
///
/// The hardware counter runs whether or not anything is listening, so what
/// happened over any stretch of time is the difference between the readings
/// bracketing it. That is the whole reason a journal fixes days the service
/// slept through: the information was never lost, only unrecorded.
///
/// **Steps are attributed to the interval's start.** They happened somewhere
/// inside it and nothing says where, so the choice is between biasing early
/// and biasing late. Early is right because the sampler takes a reading at
/// midnight: the interval that ends at 00:00 belongs to the day that just
/// finished, and the one that starts there belongs to the new day. Day
/// boundaries come out exact, and within a day the error is bounded by the
/// sampling interval rather than by how long the device slept.
StepTotals foldJournal(
  List<StepJournalEntry> entries, {
  double correctionFactor = 1.0,
}) {
  if (entries.length < 2) return StepTotals.empty;

  // Defensive: a caller reading straight from the table gets these in order,
  // but the fold is arithmetic on adjacent pairs and silently wrong if not.
  final ordered = [...entries]..sort((a, b) => a.at.compareTo(b.at));

  // A zero or negative factor would erase the day rather than correct it.
  final factor = correctionFactor > 0 ? correctionFactor : 1.0;

  final daily = <String, int>{};
  final hourly = <(String, int), int>{};

  for (var i = 0; i + 1 < ordered.length; i++) {
    final from = ordered[i];
    final to = ordered[i + 1];

    // A counter that went backwards restarted, which only happens on reboot.
    // Everything since the restart is the new reading itself; whatever
    // happened between the previous reading and the restart is unknowable and
    // is not guessed at.
    final rawDelta = to.rawSteps >= from.rawSteps
        ? to.rawSteps - from.rawSteps
        : to.rawSteps;
    if (rawDelta <= 0) continue;

    final steps = (rawDelta * factor).round();
    if (steps == 0) continue;

    final date = dateKey(from.at);
    daily[date] = (daily[date] ?? 0) + steps;

    final hour = (date, from.at.hour);
    hourly[hour] = (hourly[hour] ?? 0) + steps;
  }

  return StepTotals(daily: daily, hourly: hourly);
}
