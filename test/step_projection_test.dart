import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:step_counter/models/daily_steps.dart';
import 'package:step_counter/models/step_journal_entry.dart';
import 'package:step_counter/services/database_helper.dart';
import 'package:step_counter/services/preferences_service.dart';
import 'package:step_counter/services/step_projection.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late DatabaseHelper db;
  late StepProjection projection;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    DatabaseHelper.databasePathOverride = inMemoryDatabasePath;
    await DatabaseHelper.resetForTesting();
    db = DatabaseHelper.instance;
    projection = StepProjection(database: db, prefs: PreferencesService());
  });

  tearDown(() async {
    await DatabaseHelper.resetForTesting();
    DatabaseHelper.databasePathOverride = null;
  });

  /// Dates are relative to now so they stay inside StepProjection.window.
  DateTime ago(Duration d) => DateTime.now().subtract(d);
  String key(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  Future<void> journal(DateTime at, int raw) =>
      db.appendJournalEntry(StepJournalEntry(at: at, rawSteps: raw));

  group('project', () {
    test('a single reading derives nothing — there is no interval', () async {
      await journal(ago(const Duration(hours: 2)), 1000);

      await projection.project();

      expect(await db.getStepsForDate(key(DateTime.now())), isNull);
    });

    test('two readings derive the day between them', () async {
      final t = ago(const Duration(hours: 2));
      await journal(t, 1000);
      await journal(t.add(const Duration(minutes: 15)), 1250);

      await projection.project();

      expect((await db.getStepsForDate(key(t)))?.stepCount, 250);
    });

    test('running twice writes the same numbers', () async {
      final t = ago(const Duration(hours: 2));
      await journal(t, 1000);
      await journal(t.add(const Duration(minutes: 15)), 1250);

      await projection.project();
      await projection.project();

      expect((await db.getStepsForDate(key(t)))?.stepCount, 250,
          reason: 'the sampler, the service and a resume all call this '
              'without coordinating');
    });

    test('a gap with no readings inside it is still counted', () async {
      // The zero-step-day fix: nothing recorded for three days, then one
      // reading, and the steps taken meanwhile are recovered.
      final start = ago(const Duration(days: 4));
      await journal(start, 900000);
      await journal(start.add(const Duration(days: 3)), 930000);

      await projection.project();

      expect((await db.getStepsForDate(key(start)))?.stepCount, 30000);
    });

    test('manual credits are added on top of the sensor total', () async {
      final t = ago(const Duration(hours: 2));
      await journal(t, 1000);
      await journal(t.add(const Duration(minutes: 15)), 1250);
      await db.setManualSteps(key(t), 500);

      await projection.project();

      expect((await db.getStepsForDate(key(t)))?.stepCount, 750);
    });

    test('re-deriving a past day keeps its manual credits', () async {
      // The reason credits moved out of preferences: a projection that
      // re-derives an older day must not drop what the user added to it.
      final t = ago(const Duration(days: 3));
      await journal(t, 1000);
      await journal(t.add(const Duration(minutes: 15)), 1100);
      await db.setManualSteps(key(t), 400);

      await projection.project();
      await projection.project();

      expect((await db.getStepsForDate(key(t)))?.stepCount, 500);
    });

    test('a day with credits but no sensor steps still gets a total',
        () async {
      final t = ago(const Duration(hours: 3));
      // Two readings that move nothing, so the fold yields no daily entry.
      await journal(t, 1000);
      await journal(t.add(const Duration(minutes: 15)), 1000);
      await db.setManualSteps(key(t), 300);

      await projection.project();

      expect((await db.getStepsForDate(key(t)))?.stepCount, 300);
    });

    test('hourly totals are derived alongside daily ones', () async {
      final t = DateTime.now().subtract(const Duration(hours: 3));
      final hour = DateTime(t.year, t.month, t.day, t.hour, 5);
      await journal(hour, 1000);
      await journal(hour.add(const Duration(minutes: 20)), 1080);

      await projection.project();

      expect(await db.getHourlyStepsForDateAndHour(key(hour), hour.hour), 80);
    });

    test('journal entries past the retention window are pruned', () async {
      final old = ago(StepProjection.retention + const Duration(days: 2));
      final recent = ago(const Duration(hours: 1));
      await journal(old, 100);
      await journal(recent, 5000);
      await journal(recent.add(const Duration(minutes: 5)), 5050);

      await projection.project();

      final kept = await db.getJournalEntriesSince(
        DateTime.fromMillisecondsSinceEpoch(0),
      );
      expect(kept.any((e) => e.at.isBefore(ago(StepProjection.retention))),
          isFalse);
      expect(kept, isNotEmpty, reason: 'recent readings survive the prune');
    });
  });

  group('creditManualSteps', () {
    test('adds to the day and returns the new total', () async {
      final t = ago(const Duration(hours: 2));
      await journal(t, 1000);
      await journal(t.add(const Duration(minutes: 15)), 1200);
      await projection.project();

      final total = await projection.creditManualSteps(300, t);

      expect(total, 500);
      expect(await db.getManualSteps(key(t)), 300);
    });

    test('accumulates across several credits on one day', () async {
      final t = ago(const Duration(hours: 2));

      await projection.creditManualSteps(100, t);
      await projection.creditManualSteps(150, t);

      expect(await db.getManualSteps(key(t)), 250);
    });

    test('a non-positive amount changes nothing', () async {
      final t = ago(const Duration(hours: 2));
      await projection.creditManualSteps(200, t);

      await projection.creditManualSteps(0, t);
      await projection.creditManualSteps(-5, t);

      expect(await db.getManualSteps(key(t)), 200);
    });
  });

  group('migrateManualStepsFromPreferences', () {
    test('moves a stranded credit into the database and clears it', () async {
      final now = DateTime.now();
      final prefs = PreferencesService();
      await prefs.setManualSteps(key(now), 750);

      await projection.migrateManualStepsFromPreferences(now: now);

      expect(await db.getManualSteps(key(now)), 750);
      expect(await prefs.getManualSteps(key(now)), 0,
          reason: 'left behind it would be migrated again on the next run');
    });

    test('does not overwrite a credit the database already has', () async {
      final now = DateTime.now();
      await db.setManualSteps(key(now), 100);
      await PreferencesService().setManualSteps(key(now), 750);

      await projection.migrateManualStepsFromPreferences(now: now);

      expect(await db.getManualSteps(key(now)), 100);
    });

    test('nothing stranded is a no-op', () async {
      await projection.migrateManualStepsFromPreferences();

      expect(await db.getAllManualSteps(), isEmpty);
    });
  });

  group('backfillFromStoredTotal', () {
    test('reconstructs the opening reading so today survives the upgrade',
        () async {
      // An install that has been counting without a journal: 315 steps
      // recorded today, counter now at 40059.
      final now = DateTime.now();
      await db.upsertSteps(DailySteps(date: key(now), stepCount: 315));

      await projection.backfillFromStoredTotal(40059, now);
      await projection.project();

      expect((await db.getStepsForDate(key(now)))?.stepCount, 315,
          reason: 'the derived total must reproduce the one it replaces, '
              'not shrink to whatever the journal happens to cover');
    });

    test('the seeded reading opens the day at midnight', () async {
      final now = DateTime.now();
      await db.upsertSteps(DailySteps(date: key(now), stepCount: 200));

      await projection.backfillFromStoredTotal(5000, now);

      final seeded = (await db.getJournalEntriesSince(
        DateTime.fromMillisecondsSinceEpoch(0),
      ))
          .single;
      expect(seeded.rawSteps, 4800, reason: '5000 now minus 200 today');
      expect(seeded.at, DateTime(now.year, now.month, now.day));
    });

    test('manual credits are not reconstructed as sensor steps', () async {
      final now = DateTime.now();
      await db.setManualSteps(key(now), 100);
      await db.upsertSteps(DailySteps(date: key(now), stepCount: 300));

      await projection.backfillFromStoredTotal(5000, now);

      final seeded = (await db.getJournalEntriesSince(
        DateTime.fromMillisecondsSinceEpoch(0),
      ))
          .single;
      expect(seeded.rawSteps, 4800,
          reason: '300 stored less 100 manual is 200 of sensor steps');
    });

    test('a journal that already has entries is left alone', () async {
      final t = ago(const Duration(hours: 1));
      await journal(t, 900);

      await projection.backfillFromStoredTotal(5000, DateTime.now());

      final entries = await db.getJournalEntriesSince(
        DateTime.fromMillisecondsSinceEpoch(0),
      );
      expect(entries, hasLength(1), reason: 'seeding is a one-time repair');
    });

    test('a day with nothing stored needs no seeding', () async {
      await projection.backfillFromStoredTotal(5000, DateTime.now());

      expect(
        await db.getJournalEntriesSince(DateTime.fromMillisecondsSinceEpoch(0)),
        isEmpty,
      );
    });
  });
}
