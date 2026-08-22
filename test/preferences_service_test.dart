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

  group('manual steps', () {
    test('a credit is stored against its date', () async {
      SharedPreferences.setMockInitialValues({});

      await prefs.setManualSteps('2026-08-22', 250);

      expect(await prefs.getManualSteps('2026-08-22'), 250);
    });

    test('an unrecorded date reads as none', () async {
      SharedPreferences.setMockInitialValues({});

      expect(await prefs.getManualSteps('2026-08-22'), 0);
    });

    test('writing one drops every other day\'s', () async {
      SharedPreferences.setMockInitialValues({
        'flutter.manualSteps_2026-08-20': 100,
        'flutter.manualSteps_2026-08-21': 200,
      });

      await prefs.setManualSteps('2026-08-22', 300);

      expect(await prefs.getManualSteps('2026-08-22'), 300);
      expect(await prefs.getManualSteps('2026-08-21'), 0,
          reason: 'only the current day is ever read, and every key left '
              'behind is re-serialized on every commit');
      expect(await prefs.getManualSteps('2026-08-20'), 0);
    });

    test('pruning leaves unrelated keys alone', () async {
      SharedPreferences.setMockInitialValues({
        'flutter.manualSteps_2026-08-21': 200,
        'flutter.baseline_2026-08-22': 900000,
        'flutter.dailyTarget': 12000,
      });

      await prefs.setManualSteps('2026-08-22', 300);

      expect(await prefs.getStepBaseline('2026-08-22'), 900000);
      expect(await prefs.getDailyTarget(), 12000);
    });
  });

  group('service heartbeat', () {
    test('nothing written reads as nothing', () async {
      SharedPreferences.setMockInitialValues({});

      expect(await prefs.getServiceHeartbeat(), isNull,
          reason: 'a fresh install must not look like a stalled service');
    });

    test('a beat comes back at the moment it was written', () async {
      SharedPreferences.setMockInitialValues({});

      await prefs.setServiceHeartbeat(morning);

      expect(await prefs.getServiceHeartbeat(), morning);
    });

    test('a later beat supersedes an earlier one', () async {
      SharedPreferences.setMockInitialValues({});
      final later = morning.add(const Duration(minutes: 15));

      await prefs.setServiceHeartbeat(morning);
      await prefs.setServiceHeartbeat(later);

      expect(await prefs.getServiceHeartbeat(), later);
    });
  });
}
