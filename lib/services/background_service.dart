import 'dart:async';
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

  // Steps manually credited to today (e.g. a route logged without live
  // tracking) — added on top of the sensor-derived total below. Kept
  // separate from `baseline` so a real step never has to "know about" it;
  // it's just an extra addend applied every time the total is computed.
  int manualSteps = await prefsService.getManualSteps(_todayString());

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

  service.on('addManualSteps').listen((event) async {
    final amount = event?['steps'] as int?;
    if (amount == null || amount <= 0) return;
    final today = _todayString();
    if (trackedDate != today) {
      // No step has landed since midnight yet, so the day hasn't rolled
      // over on the sensor-driven path below — resolve it here too, so
      // this addition lands on the right day instead of yesterday's.
      trackedDate = today;
      manualSteps = await prefsService.getManualSteps(today);
      lastTodaySteps = null;
      trackedHourKey = null;
    }
    manualSteps += amount;
    await prefsService.setManualSteps(today, manualSteps);

    // Push an immediate update rather than waiting for the next real step.
    final newTotal = (lastTodaySteps ?? 0) + amount;
    lastTodaySteps = newTotal;
    final target = await prefsService.getDailyTarget();
    await dbHelper.upsertSteps(DailySteps(date: today, stepCount: newTotal));
    if (activeRoute == null) {
      await NotificationService.updateStepNotification(
        steps: newTotal,
        target: target,
      );
    }
    service.invoke('stepUpdate', {'steps': newTotal, 'target': target});
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

    if (trackedDate != today) {
      trackedDate = today;
      correctionFactor = await prefsService.getCorrectionFactor();
      baseline = await _resolveBaseline(
        dbHelper,
        today,
        event.steps,
        correctionFactor,
      );
      manualSteps = await prefsService.getManualSteps(today);
      // New day: yesterday's "day total so far" no longer applies.
      lastTodaySteps = null;
      trackedHourKey = null;
    }

    final rawDelta =
        (event.steps - (baseline ?? event.steps)).clamp(0, 1 << 30);
    final sensorSteps = (rawDelta * correctionFactor).round();
    final displaySteps = sensorSteps + manualSteps;
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
          ? displaySteps - existingHour
          : (lastTodaySteps ?? displaySteps);
    }
    final hourlySteps =
        (displaySteps - (hourStartDayTotal ?? displaySteps)).clamp(0, 1 << 30);

    await dbHelper.upsertSteps(
      DailySteps(date: today, stepCount: displaySteps),
    );
    await dbHelper.upsertHourlySteps(today, currentHour, hourlySteps);
    lastTodaySteps = displaySteps;

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
        steps: displaySteps,
        target: target,
      );
    }

    service.invoke('stepUpdate', {'steps': displaySteps, 'target': target});
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
