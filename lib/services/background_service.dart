import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart' show visibleForTesting;
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

  // Hourly bucketing: hourStartDayTotal is the day's running total when
  // the current hour began — same idea as the daily baseline, one level in.
  String? trackedHourKey;
  int? hourStartDayTotal;
  int? lastTodaySteps;

  // Latest raw sensor value, updated on every event. Seeds a new route
  // session's baseline immediately — seeding from the *next* event instead
  // would absorb that event's own step into "establishing zero" (see
  // startCalibrationTest in pedometer_service.dart for the same bug/fix).
  int? lastKnownRawSteps;

  // The route currently being tracked, or null. Baselined against the raw
  // sensor value (not today's corrected total) so it survives a midnight
  // rollover without resetting.
  Map<String, Object?>? activeRoute;

  final savedRoute = await prefsService.getActiveRoute();
  if (savedRoute != null) {
    activeRoute = {
      'id': savedRoute['routeId'] as int,
      'name': savedRoute['routeName'] as String,
      'startTime': DateTime.parse(savedRoute['startTime'] as String),
      'rawBaseline': savedRoute['rawBaseline'] as int?,
    };
  }

  // Applies a live recalibration immediately, instead of waiting for the
  // daily baseline refresh below to pick up the new factor from prefs.
  service.on('setCorrectionFactor').listen((event) {
    final factor = (event?['factor'] as num?)?.toDouble();
    if (factor != null) correctionFactor = factor;
  });

  service.on('startRoute').listen((event) async {
    final id = event?['routeId'] as int?;
    final name = event?['routeName'] as String?;
    if (id == null || name == null) return;
    final startTime = DateTime.now();
    activeRoute = {
      'id': id,
      'name': name,
      'startTime': startTime,
      'rawBaseline': lastKnownRawSteps,
    };
    await prefsService.setActiveRoute(
      routeId: id,
      routeName: name,
      startTime: startTime,
      rawBaseline: lastKnownRawSteps,
    );
  });

  service.on('stopRoute').listen((event) async {
    activeRoute = null;
    await prefsService.clearActiveRoute();
    // Revert the notification immediately rather than waiting for the
    // next step event.
    final target = await prefsService.getDailyTarget();
    await NotificationService.updateStepNotification(
      steps: lastTodaySteps ?? 0,
      target: target,
    );
  });

  // The date check below only runs on a step event, which can be hours
  // after midnight — until then the notification shows yesterday's count.
  // Schedule a single midnight timer instead of polling for it (skipped
  // while a route is active, so it doesn't stomp the route notification).
  _scheduleMidnightNotificationReset(prefsService, () => activeRoute != null);

  Pedometer.stepCountStream.listen((event) async {
    final now = DateTime.now();
    final today = _todayString();
    lastKnownRawSteps = event.steps;

    // A reading below the baseline means the hardware counter restarted —
    // it counts from the last boot, so a reboot zeroes it.
    final sensorReset = baseline != null && event.steps < baseline!;

    if (trackedDate != today || sensorReset) {
      trackedDate = today;
      correctionFactor = await prefsService.getCorrectionFactor();
      baseline = await _resolveBaseline(
        dbHelper,
        today,
        event.steps,
        correctionFactor,
      );
      // New day's — or a re-baselined day's — running total no longer lines up.
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
      // If this hour already has a persisted count (service restarted
      // mid-hour), resume from it instead of resetting or double
      // counting. Otherwise start from the previous event's day-total so
      // this hour's first step shows up right away.
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
    lastTodaySteps = todaySteps;

    // Steps always count toward the daily total above regardless of an
    // active route — only the notification display branches.
    final route = activeRoute;
    if (route != null) {
      // rawBaseline is already set unless a route started before this
      // service had ever seen a step — rare fallback, still absorbs one.
      final routeBaseline = (route['rawBaseline'] as int?) ?? event.steps;
      if (route['rawBaseline'] == null) {
        route['rawBaseline'] = routeBaseline;
        await prefsService.setActiveRoute(
          routeId: route['id'] as int,
          routeName: route['name'] as String,
          startTime: route['startTime'] as DateTime,
          rawBaseline: routeBaseline,
        );
      }
      final routeRawDelta = (event.steps - routeBaseline).clamp(0, 1 << 30);
      final routeSteps = (routeRawDelta * correctionFactor).round();
      await NotificationService.updateRouteNotification(
        routeName: route['name'] as String,
        steps: routeSteps,
        elapsed: now.difference(route['startTime'] as DateTime),
      );
      service.invoke('routeUpdate', {'steps': routeSteps});
    } else {
      await NotificationService.updateStepNotification(
        steps: todaySteps,
        target: target,
      );
    }

    service.invoke('stepUpdate', {'steps': todaySteps, 'target': target});
    service.invoke('rawStep', {'raw': event.steps});
  });
}

/// Fires once at the next local midnight, resets the notification to
/// 0/target, and reschedules itself for the following midnight. Doesn't
/// touch the sensor/baseline state — that resolves on the first real
/// step regardless; this just stops the notification from lagging.
/// Skipped while [isRouteActive], so it doesn't overwrite a route notification.
void _scheduleMidnightNotificationReset(
  PreferencesService prefsService,
  bool Function() isRouteActive,
) {
  final now = DateTime.now();
  final nextMidnight = DateTime(now.year, now.month, now.day + 1);
  Timer(nextMidnight.difference(now), () async {
    if (!isRouteActive()) {
      final target = await prefsService.getDailyTarget();
      await NotificationService.updateStepNotification(steps: 0, target: target);
    }
    _scheduleMidnightNotificationReset(prefsService, isRouteActive);
  });
}

/// Reads the stored baseline for [date], re-derives if sensor has restarted
/// since baseline write, at most once a day (plus once per sensor reset)
Future<int> _resolveBaseline(
  DatabaseHelper dbHelper,
  String date,
  int rawCumulative,
  double correctionFactor,
) async {
  final prefs = await SharedPreferences.getInstance();
  final key = 'baseline_$date';

  final existing = await dbHelper.getStepsForDate(date);
  final baseline = resolveBaselineValue(
    rawCumulative: rawCumulative,
    savedBaseline: prefs.getInt(key),
    existingSteps: existing?.stepCount ?? 0,
    correctionFactor: correctionFactor,
  );

  await prefs.setInt(key, baseline);
  final keysToRemove = prefs
      .getKeys()
      .where((k) => k.startsWith('baseline_') && k != key);
  for (final k in keysToRemove) {
    await prefs.remove(k);
  }

  return baseline;
}

/// The raw-sensor value that counts as "zero steps" for a day.
///
/// Split out from [_resolveBaseline] as pure arithmetic so the reboot case
/// is testable without a sensor, a database, or a service isolate.
@visibleForTesting
int resolveBaselineValue({
  required int rawCumulative,
  required int? savedBaseline,
  required int existingSteps,
  required double correctionFactor,
}) {
  if (savedBaseline != null && rawCumulative >= savedBaseline) {
    return savedBaseline;
  }
  final rawExistingDelta =
      correctionFactor == 0 ? 0 : (existingSteps / correctionFactor).round();
  return rawCumulative - rawExistingDelta;
}

String _todayString() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}
