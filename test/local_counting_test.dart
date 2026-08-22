import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:step_counter/services/database_helper.dart';
import 'package:step_counter/services/pedometer_service.dart';
import 'package:step_counter/services/preferences_service.dart';
import 'package:step_counter/services/step_projection.dart';

/// Guards the regression where turning the ongoing notification off left the
/// displayed count frozen: with no service running, nothing was pushing
/// totals to the UI at all, and the number only moved when a resume happened
/// to re-read the database — always one resume behind.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late PedometerService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    DatabaseHelper.databasePathOverride = inMemoryDatabasePath;
    await DatabaseHelper.resetForTesting();
    service = PedometerService(
      projection: StepProjection(
        database: DatabaseHelper.instance,
        prefs: PreferencesService(),
      ),
    );
    await service.startLocalCountingForTest();
  });

  tearDown(() async {
    await DatabaseHelper.resetForTesting();
    DatabaseHelper.databasePathOverride = null;
  });

  test('a reading with no service running reaches the display', () async {
    final seen = <int>[];
    service.todayStepsStream.listen(seen.add);

    final start = DateTime.now();
    await service.recordLocalReading(1000, start);
    await service.recordLocalReading(1120, start.add(const Duration(minutes: 1)));
    await Future<void>.delayed(Duration.zero);

    expect(seen, isNotEmpty,
        reason: 'the whole bug was that nothing was ever pushed here');
    expect(seen.last, 120);
  });

  test('the display keeps moving without any resume', () async {
    final seen = <int>[];
    service.todayStepsStream.listen(seen.add);

    final start = DateTime.now();
    await service.recordLocalReading(1000, start);
    for (var i = 1; i <= 3; i++) {
      await service.recordLocalReading(
        1000 + i * 50,
        start.add(Duration(seconds: i * 10)),
      );
    }
    await Future<void>.delayed(Duration.zero);

    expect(seen.last, 150,
        reason: 'steps must accumulate live, not wait for the app to be '
            'backgrounded and reopened');
    expect(seen.length, greaterThan(1),
        reason: 'every reading updates the display, not just the last');
  });

  test('readings before local counting is armed are ignored, not crashed',
      () async {
    final idle = PedometerService();

    await expectLater(idle.recordLocalReading(1000), completes);
  });
}
