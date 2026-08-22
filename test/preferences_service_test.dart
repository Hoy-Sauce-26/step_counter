import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:step_counter/services/preferences_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final prefs = PreferencesService();
  final morning = DateTime(2026, 8, 17, 7, 30);

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
        'flutter.dailyTarget': 12000,
      });

      await prefs.setManualSteps('2026-08-22', 300);

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

  group('removeSupersededKeys', () {
    test('clears baselines and last-raw readings the journal replaced',
        () async {
      SharedPreferences.setMockInitialValues({
        'flutter.lastRawReading': '40059@1787419558302',
        'flutter.roameterLastRawReading': '39978@1787417549662',
        'flutter.baseline_2026-08-22': 39739,
        'flutter.roameter_baseline_2026-08-22': 39910,
        'flutter.lastRawSteps': 503000,
        'flutter.lastRawStepsAt': 1787417549662,
      });

      await prefs.removeSupersededKeys();

      final remaining = (await SharedPreferences.getInstance()).getKeys();
      expect(remaining, isEmpty);
    });

    test('leaves live settings alone', () async {
      SharedPreferences.setMockInitialValues({
        'flutter.baseline_2026-08-22': 39739,
        'flutter.dailyTarget': 12000,
        'flutter.serviceHeartbeat': 1787420374626,
        'flutter.foregroundTrackingEnabled': false,
      });

      await prefs.removeSupersededKeys();

      expect(await prefs.getDailyTarget(), 12000);
      expect(await prefs.getServiceHeartbeat(), isNotNull);
      expect(await prefs.getForegroundTrackingEnabled(), isFalse);
    });

    test('nothing to clear is a no-op', () async {
      SharedPreferences.setMockInitialValues({'flutter.dailyTarget': 9000});

      await prefs.removeSupersededKeys();

      expect(await prefs.getDailyTarget(), 9000);
    });
  });
}
