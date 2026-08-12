import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:pedometer/pedometer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/daily_steps.dart';
import 'database_helper.dart';
import 'notification_service.dart';
import 'preferences_service.dart';

const backgroundNotificationChannelId = 'step_counter_channel';
const backgroundNotificationId = 888;

Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onServiceStart,
      autoStart: false,
      isForegroundMode: true,
      autoStartOnBoot: true,
      notificationChannelId: backgroundNotificationChannelId,
      initialNotificationTitle: 'Roamfree',
      initialNotificationContent: 'Starting…',
      foregroundServiceNotificationId: backgroundNotificationId,
    ),
    // No iOS equivalent for this feature — see prior discussion.
    iosConfiguration: IosConfiguration(),
  );
}

/// This is the only place in the app that calls `Pedometer.stepCountStream.listen()`
@pragma('vm:entry-point')
void onServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  await NotificationService.init();

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });
    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });
  }
  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  final prefsService = PreferencesService();
  final dbHelper = DatabaseHelper.instance;

  String? trackedDate;
  int? baseline;
  double correctionFactor = await prefsService.getCorrectionFactor();

  // Hourly-bucket tracking. `hourStartDayTotal` is the day's cumulative
  // total at the moment the current hour began — an hour's step count is
  // just (today's running total right now) minus that value, mirroring
  // exactly how the daily baseline works, one level nested.
  String? trackedHourKey;
  int? hourStartDayTotal;
  int? lastTodaySteps;

  Pedometer.stepCountStream.listen((event) async {
    final now = DateTime.now();
    final today = _todayString();

    if (trackedDate != today) {
      trackedDate = today;
      correctionFactor = await prefsService.getCorrectionFactor();
      baseline = await _resolveBaseline(
        dbHelper,
        today,
        event.steps,
        correctionFactor,
      );
      // New day: yesterday's "day total so far" no longer applies.
      lastTodaySteps = null;
      trackedHourKey = null;
    }

    final rawDelta =
        (event.steps - (baseline ?? event.steps)).clamp(0, 1 << 30);
    final todaySteps = (rawDelta * correctionFactor).round();
    final target = await prefsService.getDailyTarget();

    // Hourly bucketing.
    final currentHour = now.hour;
    final hourKey = '$today-$currentHour';
    if (trackedHourKey != hourKey) {
      trackedHourKey = hourKey;
      // If this specific hour already has a persisted count (the service
      // restarted mid-hour, e.g. after a reboot), reconstruct the
      // baseline from it so this hour resumes rather than resets or
      // double-counts. Otherwise, this is a genuinely fresh hour — treat
      // the day-total as of the previous event as its starting point, so
      // this very first event's own step(s) show up immediately rather
      // than waiting for a second event in the same hour.
      final existingHour =
          await dbHelper.getHourlyStepsForDateAndHour(today, currentHour);
      hourStartDayTotal = existingHour != null
          ? todaySteps - existingHour
          : (lastTodaySteps ?? todaySteps);
    }
    final hourlySteps =
        (todaySteps - (hourStartDayTotal ?? todaySteps)).clamp(0, 1 << 30);

    await dbHelper.upsertSteps(
      DailySteps(date: today, stepCount: todaySteps),
    );
    await dbHelper.upsertHourlySteps(today, currentHour, hourlySteps);
    await NotificationService.updateStepNotification(
      steps: todaySteps,
      target: target,
    );

    lastTodaySteps = todaySteps;

    service.invoke('stepUpdate', {'steps': todaySteps, 'target': target});
    service.invoke('rawStep', {'raw': event.steps});
  });
}

Future<int> _resolveBaseline(
  DatabaseHelper dbHelper,
  String date,
  int rawCumulative,
  double correctionFactor,
) async {
  final prefs = await SharedPreferences.getInstance();
  final key = 'baseline_$date';

  final saved = prefs.getInt(key);
  if (saved != null) return saved;

  final existing = await dbHelper.getStepsForDate(date);
  final rawExistingDelta = existing == null
      ? 0
      : (correctionFactor == 0
          ? 0
          : (existing.stepCount / correctionFactor).round());
  final baseline = rawCumulative - rawExistingDelta;

  await prefs.setInt(key, baseline);
  final keysToRemove = prefs
      .getKeys()
      .where((k) => k.startsWith('baseline_') && k != key);
  for (final k in keysToRemove) {
    await prefs.remove(k);
  }

  return baseline;
}

String _todayString() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}
