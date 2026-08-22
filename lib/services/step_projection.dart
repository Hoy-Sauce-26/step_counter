import 'package:flutter/foundation.dart';

import '../models/daily_steps.dart';
import '../models/step_journal_entry.dart';
import 'database_helper.dart';
import 'formatting.dart';
import 'preferences_service.dart';
import 'step_journal.dart';

/// Turns journalled counter readings into the stored daily and hourly totals
/// the app displays.
///
/// This is what makes a day the service slept through recoverable: the totals
/// are derived from the journal rather than accumulated live, so a reading
/// taken after a gap fills the gap in.
class StepProjection {
  StepProjection({DatabaseHelper? database, PreferencesService? prefs})
      : _db = database ?? DatabaseHelper.instance,
        _prefs = prefs ?? PreferencesService();

  final DatabaseHelper _db;
  final PreferencesService _prefs;

  /// How much history a projection re-derives. Comfortably more than the
  /// seven days the charts show, so an ordinary gap is always inside it.
  static const Duration window = Duration(days: 14);

  /// How long journalled readings are kept. The totals they were folded into
  /// outlive them — this is a rolling buffer, not the archive.
  static const Duration retention = Duration(days: 30);

  /// Records a reading and re-derives everything the journal now covers.
  Future<void> record(StepJournalEntry entry) async {
    await _db.appendJournalEntry(entry);
    await project();
  }

  /// Re-derives stored totals from the journal.
  ///
  /// Idempotent: running it twice over the same journal writes the same
  /// numbers, which is what lets the sampler, the foreground service and an
  /// app resume all call it without coordinating.
  Future<void> project({DateTime? now}) async {
    final at = now ?? DateTime.now();
    final since = at.subtract(window);

    final entries = await _db.getJournalEntriesSince(since);
    if (entries.length < 2) return;

    final totals = foldJournal(
      entries,
      correctionFactor: await _prefs.getCorrectionFactor(),
    );
    final manual = await _db.getAllManualSteps();

    // Manual credits are added here rather than folded in, because nobody
    // walked them: they belong to the day's displayed total and to no hour.
    for (final entry in totals.daily.entries) {
      await _db.upsertSteps(DailySteps(
        date: entry.key,
        stepCount: entry.value + (manual[entry.key] ?? 0),
      ));
    }

    // A day with credits but no sensor steps still has a total to show.
    for (final entry in manual.entries) {
      if (totals.daily.containsKey(entry.key)) continue;
      if (entry.key.compareTo(dateKey(since)) < 0) continue;
      await _db.upsertSteps(
        DailySteps(date: entry.key, stepCount: entry.value),
      );
    }

    for (final entry in totals.hourly.entries) {
      final (date, hour) = entry.key;
      await _db.upsertHourlySteps(date, hour, entry.value);
    }

    await _db.pruneJournal(at.subtract(retention));
  }

  /// The newest journalled reading, or null if the journal is empty.
  Future<StepJournalEntry?> latestEntry() => _db.getLatestJournalEntry();

  /// The stored total for [date], or zero if nothing is recorded yet.
  Future<int> storedTotalFor(String date) async =>
      (await _db.getStepsForDate(date))?.stepCount ?? 0;

  /// Credits steps the sensor never saw and re-derives the day.
  /// Returns the day's new displayed total.
  Future<int> creditManualSteps(int amount, DateTime at) async {
    if (amount <= 0) return (await _db.getStepsForDate(dateKey(at)))?.stepCount ?? 0;

    final date = dateKey(at);
    await _db.setManualSteps(date, await _db.getManualSteps(date) + amount);
    await project(now: at);
    return (await _db.getStepsForDate(date))?.stepCount ?? 0;
  }

  /// Seeds the journal so an install that has been counting without one
  /// keeps the total it already has.
  ///
  /// Derived totals replace stored ones, so a journal that starts mid-morning
  /// would otherwise shrink today to whatever it happens to cover. The stored
  /// total says how many steps today holds and the counter says where it is
  /// now; working backwards gives the reading today started from, which is
  /// exactly the journal entry that was never written. Writing it makes the
  /// fold reproduce the day it is replacing.
  ///
  /// Only ever runs against an empty journal.
  Future<void> backfillFromStoredTotal(int currentRaw, DateTime now) async {
    if (await _db.getLatestJournalEntry() != null) return;

    final date = dateKey(now);
    final stored = await storedTotalFor(date);
    final manual = await _db.getManualSteps(date);
    final sensorSteps = stored - manual;
    if (sensorSteps <= 0) return;

    final factor = await _prefs.getCorrectionFactor();
    final rawDelta = (sensorSteps / (factor > 0 ? factor : 1.0)).round();
    final startOfDay = DateTime(now.year, now.month, now.day);

    debugPrint('[StepProjection] seeding journal at $startOfDay so today\'s '
        '$stored steps survive the upgrade');
    await _db.appendJournalEntry(StepJournalEntry(
      at: startOfDay,
      // A counter below the day's own delta would mean it reset today, in
      // which case there is nothing coherent to reconstruct.
      rawSteps: currentRaw - rawDelta < 0 ? 0 : currentRaw - rawDelta,
    ));
  }

  /// Moves a manual credit still sitting in preferences into the database.
  ///
  /// Only the current day can be stranded there: preferences kept one date at
  /// a time, and every earlier credit is already folded into that day's
  /// stored total. Runs once — the preference is cleared after.
  Future<void> migrateManualStepsFromPreferences({DateTime? now}) async {
    final date = dateKey(now ?? DateTime.now());
    final stranded = await _prefs.getManualSteps(date);
    if (stranded <= 0) return;
    if (await _db.getManualSteps(date) > 0) return;

    debugPrint('[StepProjection] migrating $stranded manual steps for $date');
    await _db.setManualSteps(date, stranded);
    await _prefs.clearManualSteps(date);
  }
}
