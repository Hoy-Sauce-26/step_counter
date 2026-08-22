import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:step_counter/services/database_helper.dart';
import 'package:step_counter/services/live_step_counter.dart';
import 'package:step_counter/services/preferences_service.dart';
import 'package:step_counter/services/step_projection.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late DatabaseHelper db;
  late LiveStepCounter counter;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    DatabaseHelper.databasePathOverride = inMemoryDatabasePath;
    await DatabaseHelper.resetForTesting();
    db = DatabaseHelper.instance;
    counter = LiveStepCounter(
      StepProjection(database: db, prefs: PreferencesService()),
      correctionFactor: () => 1.0,
    );
  });

  tearDown(() async {
    await DatabaseHelper.resetForTesting();
    DatabaseHelper.databasePathOverride = null;
  });

  DateTime today(int hour, int minute) {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day, hour, minute);
  }

  Future<int> journalledCount() async => (await db.getJournalEntriesSince(
        DateTime.fromMillisecondsSinceEpoch(0),
      ))
          .length;

  test('the first reading is journalled and shows nothing yet', () async {
    final reading = await counter.record(1000, today(9, 0));

    expect(await journalledCount(), 1);
    expect(reading.displaySteps, 0,
        reason: 'one reading is not an interval — nothing is derived yet');
  });

  test('steps since the last write show without journalling again', () async {
    await counter.record(1000, today(9, 0));

    final reading = await counter.record(1120, today(9, 1));

    expect(reading.displaySteps, 120);
    expect(await journalledCount(), 1,
        reason: 'a minute in, the interval has not elapsed');
  });

  test('a reading past the interval is journalled', () async {
    await counter.record(1000, today(9, 0));

    await counter.record(1200, today(9, 6));

    expect(await journalledCount(), 2);
  });

  test('the hour turning journals even inside the interval', () async {
    await counter.record(1000, today(9, 58));

    await counter.record(1050, today(10, 1));

    expect(await journalledCount(), 2,
        reason: 'an entry on the boundary is what lets the fold attribute '
            'the hour exactly');
  });

  test('the derived total and live steps add up across a journal write',
      () async {
    await counter.record(1000, today(9, 0));
    await counter.record(1200, today(9, 6)); // journals, derives 200
    final reading = await counter.record(1250, today(9, 7));

    expect(reading.displaySteps, 250,
        reason: '200 derived from the journal plus 50 since the last write');
  });

  test('manual credits are included once the day is re-derived', () async {
    await counter.record(1000, today(9, 0));
    await counter.record(1200, today(9, 6));
    await db.setManualSteps(
      '${today(9, 0).year.toString().padLeft(4, '0')}-'
      '${today(9, 0).month.toString().padLeft(2, '0')}-'
      '${today(9, 0).day.toString().padLeft(2, '0')}',
      300,
    );

    await counter.record(1300, today(9, 12)); // journals + re-derives
    final reading = await counter.record(1310, today(9, 13));

    expect(reading.displaySteps, 610,
        reason: '300 sensor + 300 manual, plus 10 since the last write');
  });

  test('the correction factor scales what has not been journalled yet',
      () async {
    var factor = 1.0;
    final scaled = LiveStepCounter(
      StepProjection(database: db, prefs: PreferencesService()),
      correctionFactor: () => factor,
    );
    await scaled.record(1000, today(9, 0));

    factor = 1.1;
    final reading = await scaled.record(1100, today(9, 1));

    expect(reading.displaySteps, 110);
  });

  test('a reading that goes backwards never shows negative steps', () async {
    await counter.record(1000, today(9, 0));

    final reading = await counter.record(40, today(9, 1));

    expect(reading.displaySteps, greaterThanOrEqualTo(0),
        reason: 'a reboot mid-interval must not read as negative progress');
  });

  test('flush commits the current reading', () async {
    await counter.record(1000, today(9, 0));
    await counter.record(1150, today(9, 1)); // not journalled

    await counter.flush(1150, today(9, 2));

    expect(await journalledCount(), 2,
        reason: 'the steps since the last write must not wait on a timer '
            'that will never fire');
  });

  group('event times', () {
    test('a reading buffered through a sleep is filed when it happened',
        () async {
      await counter.record(1000, today(22, 0));

      // Delivered at 07:00 the next morning, but the counter reached this
      // value at 22:30 the night before.
      final morning = today(22, 0).add(const Duration(hours: 9));
      await counter.record(
        1200,
        morning,
        observedAt: today(22, 30),
      );

      final entries = await db.getJournalEntriesSince(
        DateTime.fromMillisecondsSinceEpoch(0),
      );
      expect(entries.last.at.hour, 22,
          reason: 'a night walk belongs to the night, not to the morning '
              'the phone happened to wake up in');
    });

    test('an event time in the future is refused', () async {
      await counter.record(1000, today(9, 0));

      await counter.record(
        1100,
        today(9, 6),
        observedAt: today(23, 0),
      );

      final entries = await db.getJournalEntriesSince(
        DateTime.fromMillisecondsSinceEpoch(0),
      );
      expect(entries.last.at.hour, 9,
          reason: 'nothing can have been observed in the future');
    });

    test('no event time falls back to now', () async {
      await counter.record(1000, today(9, 0));
      await counter.record(1100, today(9, 6));

      final entries = await db.getJournalEntriesSince(
        DateTime.fromMillisecondsSinceEpoch(0),
      );
      expect(entries.last.at.minute, 6);
    });

    test('journal cadence still follows the wall clock, not event times',
        () async {
      await counter.record(1000, today(9, 0));

      // Event time way back, but only a minute of real time has passed.
      await counter.record(1100, today(9, 1), observedAt: today(8, 0));

      expect(await journalledCount(), 1,
          reason: 'how often to journal is a question about elapsed real '
              'time, not about when the steps happened');
    });
  });
}
