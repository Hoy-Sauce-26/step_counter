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

  // Hourly bucketing: hourStartDayTotal is the day's running total when
  // the current hour began — same idea as the daily baseline, one level in.
  String? trackedHourKey;
  int? hourStartDayTotal;
  int? lastTodaySteps;

  // The most recent raw cumulative sensor value seen, updated on every
  // event regardless of a walk. Used to seed a new walk's baseline
  // immediately instead of waiting for the next event — seeding from the
  // *next* event would silently absorb that event's own step(s) into
  // "establishing zero" instead of counting them (the same off-by-one the
  // calibration test had, from sharing this same lazy-baseline idea — see
  // startCalibrationTest in pedometer_service.dart, fixed the same way).
  int? lastKnownRawSteps;

  // The route/walk currently being tracked, or null. Baselined against
  // the raw cumulative sensor value (not today's already-corrected
  // total), so a walk survives a midnight rollover without resetting,
  // unlike an earlier prototype of this feature.
  Map<String, Object?>? activeWalk;

  final savedWalk = await prefsService.getActiveWalk();
  if (savedWalk != null) {
    activeWalk = {
      'id': savedWalk['routeId'] as int,
      'name': savedWalk['routeName'] as String,
      'startTime': DateTime.parse(savedWalk['startTime'] as String),
      'rawBaseline': savedWalk['rawBaseline'] as int?,
    };
  }

  // Applies a live recalibration immediately, instead of waiting for the
  // daily baseline refresh below to pick up the new factor from prefs.
  service.on('setCorrectionFactor').listen((event) {
    final factor = (event?['factor'] as num?)?.toDouble();
    if (factor != null) correctionFactor = factor;
  });

  service.on('startWalk').listen((event) async {
    final id = event?['routeId'] as int?;
    final name = event?['routeName'] as String?;
    if (id == null || name == null) return;
    final startTime = DateTime.now();
    activeWalk = {
      'id': id,
      'name': name,
      'startTime': startTime,
      'rawBaseline': lastKnownRawSteps,
    };
    await prefsService.setActiveWalk(
      routeId: id,
      routeName: name,
      startTime: startTime,
      rawBaseline: lastKnownRawSteps,
    );
  });

  service.on('stopWalk').listen((event) async {
    activeWalk = null;
    await prefsService.clearActiveWalk();
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
  // Schedule a single midnight timer instead of polling for it. Skipped
  // while a walk is active so it doesn't stomp the walk notification.
  _scheduleMidnightNotificationReset(prefsService, () => activeWalk != null);

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
    // active walk — only the notification display branches.
    final walk = activeWalk;
    if (walk != null) {
      // rawBaseline is normally already set (from lastKnownRawSteps when
      // the walk started). Null only if a walk started before this
      // service had ever seen a single step — fall back to the old lazy
      // resolution for that rare case (still absorbs one step, but there's
      // no prior reading to anchor to).
      final walkBaseline = (walk['rawBaseline'] as int?) ?? event.steps;
      if (walk['rawBaseline'] == null) {
        walk['rawBaseline'] = walkBaseline;
        await prefsService.setActiveWalk(
          routeId: walk['id'] as int,
          routeName: walk['name'] as String,
          startTime: walk['startTime'] as DateTime,
          rawBaseline: walkBaseline,
        );
      }
      final walkRawDelta = (event.steps - walkBaseline).clamp(0, 1 << 30);
      final walkSteps = (walkRawDelta * correctionFactor).round();
      await NotificationService.updateWalkNotification(
        walkName: walk['name'] as String,
        steps: walkSteps,
        elapsed: now.difference(walk['startTime'] as DateTime),
      );
      service.invoke('walkUpdate', {'steps': walkSteps});
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
/// Skipped while [isWalkActive] — a walk notification shouldn't be
/// overwritten by the daily reset.
void _scheduleMidnightNotificationReset(
  PreferencesService prefsService,
  bool Function() isWalkActive,
) {
  final now = DateTime.now();
  final nextMidnight = DateTime(now.year, now.month, now.day + 1);
  Timer(nextMidnight.difference(now), () async {
    if (!isWalkActive()) {
      final target = await prefsService.getDailyTarget();
      await NotificationService.updateStepNotification(steps: 0, target: target);
    }
    _scheduleMidnightNotificationReset(prefsService, isWalkActive);
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
