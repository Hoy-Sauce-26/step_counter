import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:step_counter/services/preferences_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final prefs = PreferencesService();
  final morning = DateTime(2026, 8, 17, 7, 30);

  test('nothing stored reads as nothing', () async {
    SharedPreferences.setMockInitialValues({});

    expect(await prefs.getLastRawReading(), isNull);
  });

  test('a written reading comes back whole', () async {
    SharedPreferences.setMockInitialValues({});

    await prefs.setLastRawReading(LastRawReading(raw: 4200, at: morning));
    final stored = await prefs.getLastRawReading();

    expect(stored?.raw, 4200);
    expect(stored?.at, morning);
  });

  test('an upgrade keeps the count stored under the old key', () async {
    SharedPreferences.setMockInitialValues({'lastRawSteps': 503000});

    final stored = await prefs.getLastRawReading();

    expect(stored?.raw, 503000, reason: 'losing it hides the next reboot');
    expect(stored?.at, isNull, reason: 'that build recorded no time');
  });

  test('the first write after an upgrade supersedes the old key', () async {
    SharedPreferences.setMockInitialValues({'lastRawSteps': 503000});

    await prefs.setLastRawReading(LastRawReading(raw: 503100, at: morning));
    final stored = await prefs.getLastRawReading();

    expect(stored?.raw, 503100);
    expect(stored?.at, morning,
        reason: 'the stale key must not shadow the combined one');
  });

  test('a corrupt stored value reads as nothing rather than throwing',
      () async {
    // Every reading goes through this. Throwing here would stop the count for
    // the life of the install; starting over costs one day's baseline.
    SharedPreferences.setMockInitialValues({'lastRawReading': 'nonsense'});

    expect(await prefs.getLastRawReading(), isNull);
  });
}
