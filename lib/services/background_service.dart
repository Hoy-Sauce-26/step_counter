import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';

import 'package:flutter/foundation.dart'
    show debugPrint, kDebugMode, visibleForTesting;
import 'package:roameter/roameter.dart';
import 'formatting.dart';
import 'notification_service.dart';
import 'notification_throttle.dart';
import 'live_step_counter.dart';
import 'preferences_service.dart';
import 'service_channel.dart' as channel;
import 'tracking_service.dart';
import 'step_projection.dart';

/// Starts the tracking service, registering [onServiceStart] as what it runs.
/// Idempotent — starting a running service is a no-op on the platform side.
Future<void> initializeBackgroundService() async {
  await TrackingService().start(onServiceStart);
}

/// The only place in the app that subscribes to the step sensor.
@pragma('vm:entry-point')
void onServiceStart() async {
  // This isolate is entered directly from Kotlin, so nothing has set up the
  // binding the way a normal app launch would. Every platform channel below —
  // notifications, preferences, sqflite, the sensor — needs it first.
  WidgetsFlutterBinding.ensureInitialized();

  // TEMP DIAGNOSTIC — stepUpdate seen doubled once, not reproduced since.
  // Distinct tags per isolate would confirm two service starts.
  final isolateTag = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  if (kDebugMode) {
    debugPrint('[BackgroundService] onServiceStart ENTER tag=$isolateTag');
  }

  DartPluginRegistrant.ensureInitialized();
  final service = TrackingServiceInstance();
  await NotificationService.init();

  final prefsService = PreferencesService();

  // Rewriting the notification per step is wasted work.
  final notifications = NotificationThrottle();

  final projection = StepProjection();
  // Anything left in preferences from before credits became per-date rows.
  await projection.migrateManualStepsFromPreferences();

  // A snapshot, not a live read — recalibration arrives over the channel.
  double correctionFactor = await prefsService.getCorrectionFactor();
  int dailyTarget = await prefsService.getDailyTarget();

  final counter = LiveStepCounter(
    projection,
    correctionFactor: () => correctionFactor,
  );

  int? lastKnownRawSteps;
  var journalSeeded = false;

  // No foreground/background toggle: this service is only ever foreground.
  service.on('stopService').listen((event) async {
    // Commit before going away: neither the journal nor the notification
    // gets another chance.
    final raw = lastKnownRawSteps;
    if (raw != null) await counter.flush(raw, DateTime.now());
    await notifications.flush();
    await service.stopSelf();
  });

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
    correctionFactor = factor;
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
    final steps = counter.lastDisplaySteps ?? 0;
    notifications.run(() => NotificationService.updateStepNotification(
          steps: steps,
          target: dailyTarget,
        ));
  });

  channel.addManualSteps.handle(service, (amount) async {
    final creditedAt = DateTime.now();
    final newTotal = await projection.creditManualSteps(amount, creditedAt);
    // The credit changed the day's derived total without any reading having
    // arrived, so the live counter has to pick it up.
    await counter.refresh(creditedAt);

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

  // Proof of life for [stalledFor] — immediately, then on a timer.
  Future<void> recordHeartbeat() =>
      prefsService.setServiceHeartbeat(DateTime.now());
  await recordHeartbeat();
  Timer.periodic(serviceHeartbeatInterval, (_) => recordHeartbeat());

  final sensorStatusLatch = SensorStatusLatch();
  Future<void> recordSensorStatus(bool available) async {
    if (!sensorStatusLatch.accept(available)) return;
    await prefsService.setStepSensorAvailable(available);
    channel.sensorStatus.send(service, available);
    if (!available) {
      await NotificationService.showSensorUnavailableNotification();
    }
  }

  // batchLatency zero: deliver each reading as it happens rather than letting
  // the sensor hub buffer them, which is what keeps the notification live.
  // Phase 4 turns this down for the sampler, where nobody is watching.
  const roameter = Roameter();
  roameter.stepCounts(batchLatency: Duration.zero).listen((event) async {
    // The event's own `timestamp` is deliberately not used for bucketing yet.
    // With zero batching it matches arrival to within milliseconds, except on
    // the first reading after a restart, which carries the time the count last
    // changed — possibly yesterday. Attributing by event time is Phase 5.1's
    // job and needs that case handled; this keeps today's semantics exactly.
    final now = DateTime.now();

    final rawChanged = lastKnownRawSteps != event.steps;
    lastKnownRawSteps = event.steps;
    await recordSensorStatus(true);

    // Before the first record(), so the fold has the day's opening reading.
    if (!journalSeeded) {
      journalSeeded = true;
      await projection.backfillFromStoredTotal(event.steps, now);
    }

    final reading = await counter.record(event.steps, now);
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
        correctionFactor: correctionFactor,
      );
      final routeSteps = progress.steps;

      // Skip the write if nothing moved — avoids an fsync'd commit for an
      // unchanged value.
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

    // TEMP DIAGNOSTIC — see onServiceStart.
    if (kDebugMode) {
      debugPrint('[BackgroundService] send stepUpdate=$displaySteps '
          'tag=$isolateTag');
    }

    // The date rides along so the app can tell a live figure from a stored
    // one when deciding which of the two is current.
    channel.stepUpdate.send(
      service,
      channel.StepUpdate(steps: displaySteps, date: reading.date),
    );
    // Repeats carry nothing the calibration test or route baseline needs.
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

/// How often the service records that it is alive and still listening.
const Duration serviceHeartbeatInterval = Duration(minutes: 15);

/// Three missed heartbeats before the app treats tracking as stopped, so one
/// Doze-delayed timer isn't mistaken for a dead service.
const Duration serviceHeartbeatTimeout = Duration(minutes: 45);

/// How long tracking has been silent, or null if that's within tolerance.
/// `isRunning()` only says an Android service object exists, not that the
/// isolate inside it is alive — this is the actual liveness question.
Duration? stalledFor({
  required DateTime? lastHeartbeat,
  required DateTime now,
  Duration timeout = serviceHeartbeatTimeout,
}) {
  if (lastHeartbeat == null) return null;
  final age = now.difference(lastHeartbeat);
  if (age.isNegative || age <= timeout) return null;
  return age;
}

/// A positive sensor report is terminal — hardware that produced a reading
/// exists. A negative one isn't: it can be a startup race, and latching it
/// would strand the user on "no sensor" until something overwrites it.
class SensorStatusLatch {
  bool? _recorded;

  /// Whether [available] says something not already said. Records it if so.
  bool accept(bool available) {
    if (_recorded == true) return false;
    if (_recorded == available) return false;
    _recorded = available;
    return true;
  }
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

