import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:pedometer/pedometer.dart';
import 'formatting.dart';
import 'notification_service.dart';
import 'notification_throttle.dart';
import 'preferences_service.dart';
import 'service_channel.dart' as channel;
import 'step_accumulator.dart';

Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onServiceStart,
      autoStart: false,
      isForegroundMode: true,
      autoStartOnBoot: true,
      // Can't a dataSync foreground service from BOOT_COMPLETED
      foregroundServiceTypes: [AndroidForegroundType.health],
      notificationChannelId: NotificationService.channelId,
      initialNotificationTitle: 'Roamfree',
      initialNotificationContent: 'Starting…',
      foregroundServiceNotificationId: NotificationService.notificationId,
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

  final prefsService = PreferencesService();

  // Buffered rather than written straight through:
  final stepStore = ThrottledStepStore(PersistentStepStore());

  // Same idea for the notification: a rewrite per step is invisible to the
  // reader and expensive to the system. Every update below goes through this,
  // including the immediate ones — they stay immediate unless a step landed
  // in the last second, and the trailing send covers them if one did.
  final notifications = NotificationThrottle();

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });
    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });
  }
  service.on('stopService').listen((event) async {
    // Commit before going away: neither flush timer gets another chance.
    await stepStore.flush();
    await notifications.flush();
    service.stopSelf();
  });

  // All day/hour/manual bookkeeping lives here. This isolate keeps no copy of
  // it, so there is nothing to drift out of sync.
  final accumulator = StepAccumulator(
    stepStore,
    correctionFactor: await prefsService.getCorrectionFactor(),
  );

  // A snapshot, not a live read: see StepAccumulator.correctionFactor.
  int dailyTarget = await prefsService.getDailyTarget();

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
  channel.setCorrectionFactor.handle(service, (factor) {
    accumulator.correctionFactor = factor;
  });

  // Same deal for the target
  channel.setDailyTarget.handle(service, (target) => dailyTarget = target);

  // This isolate is the only writer of the stored active route. The app
  // holds its own copy for the UI but must not persist it.
  channel.startRoute.handle(service, (command) async {
    final id = command.routeId;
    final name = command.routeName;
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

  channel.stopRoute.handle(service, () async {
    activeRoute = null;
    await prefsService.clearActiveRoute();
    // Revert the notification without waiting for the next step event.
    final steps = accumulator.lastDisplaySteps ?? 0;
    notifications.run(() => NotificationService.updateStepNotification(
          steps: steps,
          target: dailyTarget,
        ));
  });

  channel.addManualSteps.handle(service, (amount) async {
    final creditedAt = DateTime.now();
    final newTotal = await accumulator.creditManualSteps(amount, creditedAt);
    if (newTotal == null) return;

    // Push an update rather than waiting for the next real reading.
    if (activeRoute == null) {
      notifications.run(() => NotificationService.updateStepNotification(
            steps: newTotal,
            target: dailyTarget,
          ));
    }
    channel.stepUpdate.send(
      service,
      channel.StepUpdate(steps: newTotal, date: dateKey(creditedAt)),
    );
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
    channel.sensorStatus.send(service, available);
    if (!available) {
      await NotificationService.showSensorUnavailableNotification();
    }
  }

  Pedometer.stepCountStream.listen((event) async {
    final now = DateTime.now();
    final rawChanged = lastKnownRawSteps != event.steps;
    lastKnownRawSteps = event.steps;
    await recordSensorStatus(true);

    final reading = await accumulator.record(event.steps, now);
    final displaySteps = reading.displaySteps;

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
        correctionFactor: accumulator.correctionFactor,
      );
      final routeSteps = progress.steps;

      // Compared before the assignments below overwrite them. A reading that
      // moves nothing rewrites the whole prefs file for an identical value —
      // and SharedPreferences.setString is a blocking, fsync'd commit.
      final routeStateChanged = progress.rawBaseline != route['rawBaseline'] ||
          progress.stepsBefore != route['stepsBefore'] ||
          routeSteps != route['steps'] ||
          progress.lastRaw != route['lastRaw'];

      route['rawBaseline'] = progress.rawBaseline;
      route['stepsBefore'] = progress.stepsBefore;
      route['steps'] = routeSteps;
      route['lastRaw'] = progress.lastRaw;
      if (routeStateChanged) {
        await prefsService.setActiveRoute(
          routeId: route['id'] as int,
          routeName: route['name'] as String,
          startTime: route['startTime'] as DateTime,
          rawBaseline: progress.rawBaseline,
          stepsBefore: progress.stepsBefore,
          steps: routeSteps,
          lastRaw: progress.lastRaw,
        );
      }
      final routeName = route['name'] as String;
      final elapsed = now.difference(route['startTime'] as DateTime);
      notifications.run(() => NotificationService.updateRouteNotification(
            routeName: routeName,
            steps: routeSteps,
            elapsed: elapsed,
          ));
      channel.routeUpdate.send(service, routeSteps);
    } else {
      notifications.run(() => NotificationService.updateStepNotification(
            steps: displaySteps,
            target: dailyTarget,
          ));
    }

    // The date rides along so the app can tell a live figure from a stored
    // one when deciding which of the two is current.
    channel.stepUpdate.send(
      service,
      channel.StepUpdate(steps: displaySteps, date: reading.date),
    );
    // Only the calibration test and the route baseline consume this, and
    // both care about the value rather than the event. Repeats carry nothing.
    if (rawChanged) channel.rawStep.send(service, event.steps);
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
/// reboot, which also kills the service isolate.
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

