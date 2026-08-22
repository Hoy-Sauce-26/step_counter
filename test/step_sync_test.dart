import 'package:flutter_test/flutter_test.dart';
import 'package:roameter/roameter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:step_counter/models/step_journal_entry.dart';
import 'package:step_counter/services/database_helper.dart';
import 'package:step_counter/services/preferences_service.dart';
import 'package:step_counter/services/step_projection.dart';
import 'package:step_counter/services/step_sync.dart';

/// A sensor that answers with whatever it was given, and counts the asking.
class _FakeSensor implements Roameter {
  _FakeSensor(this.reading);

  StepCountReading? reading;
  int reads = 0;

  @override
  Future<StepCountReading?> readStepCount() async {
    reads++;
    return reading;
  }

  @override
  Future<bool> isStepCountingAvailable() async => reading != null;

  @override
  Stream<StepCountReading> stepCounts({Duration batchLatency = Duration.zero}) =>
      const Stream.empty();
}

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

  StepSync syncWith(_FakeSensor sensor) =>
      StepSync(projection: projection, sensor: sensor);

  test('a reading is journalled at the moment it was taken', () async {
    final now = DateTime.now();
    final sensor = _FakeSensor(
      StepCountReading(steps: 40127, timestamp: now.subtract(const Duration(hours: 2))),
    );

    expect(await syncWith(sensor).sample(now: now), isTrue);

    final entry = await db.getLatestJournalEntry();
    expect(entry?.rawSteps, 40127);
    expect(
      entry?.at.millisecondsSinceEpoch,
      now.millisecondsSinceEpoch,
      reason: "the sensor's event time is when the count last changed, not "
          'when we observed it standing there',
    );
  });

  test('no sensor means nothing recorded', () async {
    final sensor = _FakeSensor(null);

    expect(await syncWith(sensor).sample(), isFalse);
    expect(await db.getLatestJournalEntry(), isNull);
  });

  test('a sample too soon after the last one is skipped', () async {
    final now = DateTime.now();
    await db.appendJournalEntry(
      StepJournalEntry(at: now.subtract(const Duration(seconds: 5)), rawSteps: 100),
    );
    final sensor = _FakeSensor(StepCountReading(steps: 200, timestamp: now));

    expect(await syncWith(sensor).sample(now: now), isFalse);
    expect(sensor.reads, 0, reason: 'the sensor is not even asked');
  });

  test('a sample past the interval goes through', () async {
    final now = DateTime.now();
    await db.appendJournalEntry(
      StepJournalEntry(at: now.subtract(const Duration(minutes: 5)), rawSteps: 100),
    );
    final sensor = _FakeSensor(StepCountReading(steps: 200, timestamp: now));

    expect(await syncWith(sensor).sample(now: now), isTrue);
  });

  test('force overrides the throttle', () async {
    final now = DateTime.now();
    await db.appendJournalEntry(
      StepJournalEntry(at: now.subtract(const Duration(seconds: 5)), rawSteps: 100),
    );
    final sensor = _FakeSensor(StepCountReading(steps: 200, timestamp: now));

    expect(await syncWith(sensor).sample(now: now, force: true), isTrue);
  });

  test('sampling folds the gap since the previous reading', () async {
    final now = DateTime.now();
    final earlier = now.subtract(const Duration(hours: 3));
    await db.appendJournalEntry(StepJournalEntry(at: earlier, rawSteps: 40000));
    final sensor = _FakeSensor(StepCountReading(steps: 40500, timestamp: now));

    await syncWith(sensor).sample(now: now);

    final date = '${earlier.year.toString().padLeft(4, '0')}-'
        '${earlier.month.toString().padLeft(2, '0')}-'
        '${earlier.day.toString().padLeft(2, '0')}';
    expect((await db.getStepsForDate(date))?.stepCount, 500,
        reason: 'one reading with no service running closes the whole gap');
  });
}
