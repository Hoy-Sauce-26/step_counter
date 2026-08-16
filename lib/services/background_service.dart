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

  // Both of these are snapshots, not live reads.
  double correctionFactor = await prefsService.getCorrectionFactor();
  int dailyTarget = await prefsService.getDailyTarget();

  // Steps manually credited to today (a route logged without live tracking)
  int manualSteps = await prefsService.getManualSteps(_todayString());

  // Hourly bucketing: hourStartDayTotal is the day's running total when
  // the current hour began — same idea as the daily baseline, one level in.
  String? trackedHourKey;
  // Hourly buckets track sensor steps only
  int? hourStartSensorTotal;
  int? lastSensorSteps;
  int? lastTodaySteps;

  int? lastKnownRawSteps;

  Map<String, Object?>? activeRoute;

  final savedRoute = await prefsService.getActiveRoute();
  if (savedRoute != null) {
    activeRoute = {
      'id': savedRoute['routeId'] as int,
      'name': savedRoute['routeName'] as String,
      'startTime': DateTime.parse(savedRoute['startTime'] as String),
      'rawBaseline': savedRoute['rawBaseline'] as int?,
      'stepsBefore': savedRoute['stepsBefore'] as int? ?? 0,
      'steps': savedRoute['steps'] as int? ?? 0,
      'lastRaw': savedRoute['lastRaw'] as int?,
    };
  }

  // The only way a recalibration reaches this isolate.
  service.on('setCorrectionFactor').listen((event) {
    final factor = (event?['factor'] as num?)?.toDouble();
    if (factor != null) correctionFactor = factor;
  });

  // Same deal for the target
  service.on('setDailyTarget').listen((event) {
    final target = (event?['target'] as num?)?.toInt();
    if (target != null) dailyTarget = target;
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
      'stepsBefore': 0,
      'steps': 0,
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
    await NotificationService.updateStepNotification(
      steps: lastTodaySteps ?? 0,
      target: dailyTarget,
    );
  });

  service.on('addManualSteps').listen((event) async {
    final amount = event?['steps'] as int?;
    if (amount == null || amount <= 0) return;
    final today = _todayString();
    if (trackedDate != today) {
      // A manual credit can arrive before the day's first reading, when
      // manualSteps still holds yesterday's figure. Reload it, but leave
      // trackedDate alone
      manualSteps = await prefsService.getManualSteps(today);
      lastTodaySteps = null;
      lastSensorSteps = null;
      trackedHourKey = null;
    }
    manualSteps += amount;
    await prefsService.setManualSteps(today, manualSteps);

    final runningTotal = lastTodaySteps ??
        (await dbHelper.getStepsForDate(today))?.stepCount ??
        0;
    final newTotal = runningTotal + amount;
    lastTodaySteps = newTotal;
    await dbHelper.upsertSteps(DailySteps(date: today, stepCount: newTotal));
    // Deliberately no upsertHourlySteps: these steps have no hour.
    if (activeRoute == null) {
      await NotificationService.updateStepNotification(
        steps: newTotal,
        target: dailyTarget,
      );
    }
    service.invoke('stepUpdate', {'steps': newTotal, 'target': dailyTarget});
  });

  // Schedule a single midnight timer instead of polling for it (skipped
  // while a route is active, so it doesn't stomp the route notification).
  _scheduleMidnightNotificationReset(
    () => dailyTarget,
    () => activeRoute != null,
  );

  bool sensorStatusRecorded = false;
  Future<void> recordSensorStatus(bool available) async {
    if (sensorStatusRecorded) return;
    sensorStatusRecorded = true;
    await prefsService.setStepSensorAvailable(available);
    service.invoke('sensorStatus', {'available': available});
    if (!available) {
      await NotificationService.showSensorUnavailableNotification();
    }
  }

  Pedometer.stepCountStream.listen((event) async {
    final now = DateTime.now();
    final today = _todayString();
    lastKnownRawSteps = event.steps;
    await recordSensorStatus(true);

    // A reading below the baseline means the hardware counter restarted —
    // it counts from the last boot, so a reboot zeroes it.
    final sensorReset = baseline != null && event.steps < baseline!;

    if (trackedDate != today || sensorReset) {
      trackedDate = today;
      manualSteps = await prefsService.getManualSteps(today);
      baseline = await _resolveBaseline(
        dbHelper,
        today,
        event.steps,
        correctionFactor,
        manualSteps,
      );
      // New day's — or a re-baselined day's — running total no longer lines up.
      lastTodaySteps = null;
      lastSensorSteps = null;
      trackedHourKey = null;
    }

    final rawDelta =
        (event.steps - (baseline ?? event.steps)).clamp(0, 1 << 30);
    final sensorSteps = (rawDelta * correctionFactor).round();
    final displaySteps = sensorSteps + manualSteps;

    // Hourly bucketing, over sensor steps only.
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
      hourStartSensorTotal = existingHour != null
          ? sensorSteps - existingHour
          : (lastSensorSteps ?? sensorSteps);
    }
    final hourlySteps =
        (sensorSteps - (hourStartSensorTotal ?? sensorSteps)).clamp(0, 1 << 30);

    await dbHelper.upsertSteps(
      DailySteps(date: today, stepCount: displaySteps),
    );
    await dbHelper.upsertHourlySteps(today, currentHour, hourlySteps);
    lastTodaySteps = displaySteps;
    lastSensorSteps = sensorSteps;

    // Steps always count toward the daily total above regardless of an
    // active route — only the notification display branches.
    final route = activeRoute;
    if (route != null) {
      // rawBaseline is already set unless a route started before this
      // service had ever seen a step — rare fallback, still absorbs one.
      final progress = resolveRouteProgress(
        rawCumulative: event.steps,
        rawBaseline: (route['rawBaseline'] as int?) ?? event.steps,
        stepsBefore: route['stepsBefore'] as int? ?? 0,
        bankedSteps: route['steps'] as int?,
        lastRaw: route['lastRaw'] as int?,
        correctionFactor: correctionFactor,
      );
      final routeSteps = progress.steps;

      route['rawBaseline'] = progress.rawBaseline;
      route['stepsBefore'] = progress.stepsBefore;
      route['steps'] = routeSteps;
      route['lastRaw'] = progress.lastRaw;
      await prefsService.setActiveRoute(
        routeId: route['id'] as int,
        routeName: route['name'] as String,
        startTime: route['startTime'] as DateTime,
        rawBaseline: progress.rawBaseline,
        stepsBefore: progress.stepsBefore,
        steps: routeSteps,
        lastRaw: progress.lastRaw,
      );
      await NotificationService.updateRouteNotification(
        routeName: route['name'] as String,
        steps: routeSteps,
        elapsed: now.difference(route['startTime'] as DateTime),
      );
      service.invoke('routeUpdate', {'steps': routeSteps});
    } else {
      await NotificationService.updateStepNotification(
        steps: displaySteps,
        target: dailyTarget,
      );
    }

    service.invoke('stepUpdate', {'steps': displaySteps, 'target': dailyTarget});
    service.invoke('rawStep', {'raw': event.steps});
  }, onError: (Object error) async {
    // Need this handler here for devices with no step sensor.
    await recordSensorStatus(false);
  });
}

/// Fires once at the next local midnight, resets the notification to
/// 0/target, and reschedules itself for the following midnight. Doesn't
/// touch the sensor/baseline state — that resolves on the first real
/// step regardless; this just stops the notification from lagging.
/// Skipped while [isRouteActive], so it doesn't overwrite a route notification.
void _scheduleMidnightNotificationReset(
  int Function() currentTarget,
  bool Function() isRouteActive,
) {
  final now = DateTime.now();
  final nextMidnight = DateTime(now.year, now.month, now.day + 1);
  Timer(nextMidnight.difference(now), () async {
    if (!isRouteActive()) {
      await NotificationService.updateStepNotification(
        steps: 0,
        target: currentTarget(),
      );
    }
    _scheduleMidnightNotificationReset(currentTarget, isRouteActive);
  });
}

/// Reads the stored baseline for [date], re-derives if sensor has restarted
/// since baseline write, at most once a day (plus once per sensor reset)
Future<int> _resolveBaseline(
  DatabaseHelper dbHelper,
  String date,
  int rawCumulative,
  double correctionFactor,
  int manualSteps,
) async {
  final prefs = await SharedPreferences.getInstance();
  final key = 'baseline_$date';

  final existing = await dbHelper.getStepsForDate(date);
  // Only the sensor-derived part of the stored total can be turned back into
  // a raw reading.
  final sensorSteps =
      ((existing?.stepCount ?? 0) - manualSteps).clamp(0, 1 << 30);
  final baseline = resolveBaselineValue(
    rawCumulative: rawCumulative,
    savedBaseline: prefs.getInt(key),
    existingSteps: sensorSteps,
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

/// An in-progress route's counters after folding in one raw reading.
@visibleForTesting
class RouteProgress {
  final int rawBaseline;
  final int stepsBefore;
  final int steps;
  final int lastRaw;

  const RouteProgress({
    required this.rawBaseline,
    required this.stepsBefore,
    required this.steps,
    required this.lastRaw,
  });
}

/// Advances a route's counters for one reading.
///
/// A reading below the previous one means the hardware counter restarted — a
/// reboot, which also kills the service isolate. The route's banked total
/// carries across and a fresh segment starts from here. Without that the
/// delta clamps to zero for the remainder of the walk, and because the figure
/// written to the route's history is this one, the session recorded at the
/// end would drag the route's stored average down permanently.
///
/// Detection compares against [lastRaw] rather than [rawBaseline]: the first
/// reset drops the baseline to whatever the counter read at the time, which
/// is typically zero, and nothing is ever below zero. A second reboot in the
/// same walk would then go unnoticed and lose the segment between them.
/// [rawBaseline] is still checked for the first reading after a restart,
/// where no previous reading survived.
///
/// The correction factor applies to a whole segment rather than to each
/// reading: rounding per reading drifts badly across a route's worth of
/// single-step events.
@visibleForTesting
RouteProgress resolveRouteProgress({
  required int rawCumulative,
  required int rawBaseline,
  required int stepsBefore,
  required int? bankedSteps,
  required int? lastRaw,
  required double correctionFactor,
}) {
  var baseline = rawBaseline;
  var before = stepsBefore;

  if (rawCumulative < baseline || (lastRaw != null && rawCumulative < lastRaw)) {
    before = bankedSteps ?? before;
    baseline = rawCumulative;
  }

  final delta = (rawCumulative - baseline).clamp(0, 1 << 30);
  return RouteProgress(
    rawBaseline: baseline,
    stepsBefore: before,
    steps: before + (delta * correctionFactor).round(),
    lastRaw: rawCumulative,
  );
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
