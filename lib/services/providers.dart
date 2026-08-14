import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/daily_steps.dart';
import '../models/hourly_steps.dart';
import '../models/saved_route.dart';
import 'database_helper.dart';
import 'metrics.dart';
import 'pedometer_service.dart';
import 'preferences_service.dart';

final pedometerServiceProvider = Provider<PedometerService>((ref) {
  final service = PedometerService();
  ref.onDispose(service.dispose);
  return service;
});

final preferencesServiceProvider = Provider<PreferencesService>((ref) {
  return PreferencesService();
});

final databaseHelperProvider = Provider<DatabaseHelper>((ref) {
  return DatabaseHelper.instance;
});

/// Live "steps taken today" stream, sourced from the pedometer service.
/// A value of -1 signals the sensor is unavailable.
final todayStepsProvider = StreamProvider<int>((ref) {
  final service = ref.watch(pedometerServiceProvider);
  service.start();
  return service.todayStepsStream;
});

/// 'walking' / 'stopped' / 'unknown' — no UI consumer right now, but keep
/// it running: removing it made steps arrive in laggy batches instead of
/// individually (reason unclear, possibly Android sensor batching).
final walkingStatusProvider = StreamProvider<String>((ref) {
  final service = ref.watch(pedometerServiceProvider);
  service.start();
  return service.walkingStatusStream;
});

/// The user's configured daily step target (defaults to 10,000).
final dailyTargetProvider = NotifierProvider<DailyTargetNotifier, int>(
  DailyTargetNotifier.new,
);

class DailyTargetNotifier extends Notifier<int> {
  @override
  int build() {
    _load();
    return PreferencesService.defaultDailyTarget;
  }

  Future<void> _load() async {
    state = await ref.read(preferencesServiceProvider).getDailyTarget();
  }

  Future<void> setTarget(int target) async {
    state = target;
    await ref.read(preferencesServiceProvider).setDailyTarget(target);
  }
}

/// The user's step-count calibration factor (1.0 = trust the sensor as-is).
final calibrationFactorProvider =
    NotifierProvider<CalibrationFactorNotifier, double>(
  CalibrationFactorNotifier.new,
);

class CalibrationFactorNotifier extends Notifier<double> {
  @override
  double build() {
    _load();
    return PreferencesService.defaultCorrectionFactor;
  }

  Future<void> _load() async {
    state = await ref.read(preferencesServiceProvider).getCorrectionFactor();
  }

  Future<void> setFactor(double factor) async {
    state = factor;
    await ref.read(pedometerServiceProvider).setCorrectionFactor(factor);
  }
}

/// Height in cm, if personalized. Null uses the flat-rate default — see
/// StepMetrics.distanceKm.
final heightCmProvider =
    NotifierProvider<HeightCmNotifier, double?>(
  HeightCmNotifier.new,
);

class HeightCmNotifier extends Notifier<double?> {
  @override
  double? build() {
    _load();
    return null;
  }

  Future<void> _load() async {
    state = await ref.read(preferencesServiceProvider).getHeightCm();
  }

  Future<void> setHeight(double? cm) async {
    state = cm;
    await ref.read(preferencesServiceProvider).setHeightCm(cm);
  }
}

/// Weight in kg, if personalized. Null uses the flat-rate default — see
/// StepMetrics.calories.
final weightKgProvider = NotifierProvider<WeightKgNotifier, double?>(
  WeightKgNotifier.new,
);

class WeightKgNotifier extends Notifier<double?> {
  @override
  double? build() {
    _load();
    return null;
  }

  Future<void> _load() async {
    state = await ref.read(preferencesServiceProvider).getWeightKg();
  }

  Future<void> setWeight(double? kg) async {
    state = kg;
    await ref.read(preferencesServiceProvider).setWeightKg(kg);
  }
}

/// Which unit system to display values in throughout the app.
final unitSystemProvider = NotifierProvider<UnitSystemNotifier, UnitSystem>(
  UnitSystemNotifier.new,
);

class UnitSystemNotifier extends Notifier<UnitSystem> {
  @override
  UnitSystem build() {
    _load();
    return UnitSystem.metric; // Defaults to metric.
  }

  Future<void> _load() async {
    state = await ref.read(preferencesServiceProvider).getUnitSystem();
  }

  Future<void> setSystem(UnitSystem system) async {
    state = system;
    await ref.read(preferencesServiceProvider).setUnitSystem(system);
  }
}

/// Zero-filled past 7 days, chronological. Re-fetches on app start and
/// every 100 steps (not every step) so the chart doesn't redraw
/// constantly while walking.
final _chartRefreshBucketProvider = Provider.autoDispose<int>((ref) {
  final steps = ref.watch(todayStepsProvider).value ?? 0;
  return steps ~/ 100;
});

final past7DaysProvider =
    FutureProvider.autoDispose<List<DailySteps>>((ref) async {
  ref.watch(_chartRefreshBucketProvider);
  final db = ref.watch(databaseHelperProvider);
  final records = await db.getPastNDays(7);

  final byDate = {for (final r in records) r.date: r.stepCount};
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  return List.generate(7, (i) {
    final d = today.subtract(Duration(days: 6 - i));
    final dateStr = '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    return DailySteps(date: dateStr, stepCount: byDate[dateStr] ?? 0);
  });
});

/// Zero-filled 24-hour breakdown for a date (ISO-8601, e.g. "2026-08-11").
/// Refreshes on the same throttled cadence as [past7DaysProvider] for
/// today; historical dates are static once fetched.
final hourlyStepsForDateProvider =
    FutureProvider.autoDispose.family<List<HourlySteps>, String>(
  (ref, date) async {
    final today = DateTime.now();
    final todayStr = '${today.year.toString().padLeft(4, '0')}-'
        '${today.month.toString().padLeft(2, '0')}-'
        '${today.day.toString().padLeft(2, '0')}';
    if (date == todayStr) {
      ref.watch(_chartRefreshBucketProvider);
    }

    final db = ref.watch(databaseHelperProvider);
    final records = await db.getHourlyStepsForDate(date);
    final byHour = {for (final r in records) r.hour: r.stepCount};

    return List.generate(
      24,
      (hour) => HourlySteps(
        date: date,
        hour: hour,
        stepCount: byHour[hour] ?? 0,
      ),
    );
  },
);

/// Saved routes, newest first, with each one's average step count.
/// Invalidated after adding a route or recording a session.
final routesProvider = FutureProvider<List<SavedRoute>>((ref) async {
  final db = ref.watch(databaseHelperProvider);
  return db.getRoutes();
});

/// Marks a currently in-progress walk against a saved route.
class ActiveWalk {
  final int routeId;
  final String routeName;
  final DateTime startTime;
  const ActiveWalk({
    required this.routeId,
    required this.routeName,
    required this.startTime,
  });
}

/// The walk currently being tracked, or null. Persisted to survive an app
/// restart, and mirrored to the background service (the source of truth
/// for live steps/notification) — same pattern as [CalibrationFactorNotifier].
final activeWalkProvider = NotifierProvider<ActiveWalkNotifier, ActiveWalk?>(
  ActiveWalkNotifier.new,
);

class ActiveWalkNotifier extends Notifier<ActiveWalk?> {
  @override
  ActiveWalk? build() {
    _load();
    return null;
  }

  Future<void> _load() async {
    final saved = await ref.read(preferencesServiceProvider).getActiveWalk();
    if (saved == null) return;
    state = ActiveWalk(
      routeId: saved['routeId'] as int,
      routeName: saved['routeName'] as String,
      startTime: DateTime.parse(saved['startTime'] as String),
    );
  }

  Future<void> startWalk(int routeId, String routeName) async {
    final startTime = DateTime.now();
    state = ActiveWalk(
      routeId: routeId,
      routeName: routeName,
      startTime: startTime,
    );
    await ref.read(preferencesServiceProvider).setActiveWalk(
          routeId: routeId,
          routeName: routeName,
          startTime: startTime,
        );
    FlutterBackgroundService().invoke('startWalk', {
      'routeId': routeId,
      'routeName': routeName,
    });
  }

  Future<void> stopWalk() async {
    state = null;
    await ref.read(preferencesServiceProvider).clearActiveWalk();
    FlutterBackgroundService().invoke('stopWalk');
  }
}

/// Live active-walk step count, from the background service's
/// `'walkUpdate'` broadcast. Keyed by start time so a new walk gets a
/// genuinely fresh subscription — AsyncValue otherwise carries the
/// previous walk's count across a plain `ref.invalidate`.
final activeWalkStepsProvider =
    StreamProvider.autoDispose.family<int, DateTime>((ref, walkStartTime) {
  final service = ref.watch(pedometerServiceProvider);
  return service.activeWalkStepsStream;
});
