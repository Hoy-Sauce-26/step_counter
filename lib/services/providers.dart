import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/daily_steps.dart';
import '../models/hourly_steps.dart';
import '../models/saved_route.dart';
import 'database_helper.dart';
import 'formatting.dart';
import 'metrics.dart';
import 'pedometer_service.dart';
import 'system_settings.dart';
import 'preferences_service.dart';
import 'service_channel.dart' as channel;

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

final systemSettingsProvider = Provider<SystemSettings>((ref) {
  return const SystemSettings();
});

/// Live "steps taken today" stream, sourced from the pedometer service.
final todayStepsProvider = StreamProvider<int>((ref) {
  final service = ref.watch(pedometerServiceProvider);
  service.start();
  return service.todayStepsStream;
});

final stepSensorAvailableProvider = StreamProvider<bool>((ref) {
  final service = ref.watch(pedometerServiceProvider);
  service.start();
  return service.sensorAvailableStream;
});

/// No UI consumer — kept subscribed because it holds the sensor pipeline
/// open, which is what makes the step counter deliver per-step instead of in
/// laggy batches. See `PedometerService._applyForegroundSensing`.
final walkingStatusProvider = StreamProvider<String>((ref) {
  final service = ref.watch(pedometerServiceProvider);
  service.start();
  return service.walkingStatusStream;
});

abstract class SettingNotifier<T> extends Notifier<T> {
  /// Shown until [load] returns — reads are synchronous, so there has to be
  /// something to show first.
  T get fallback;

  Future<T> load(PreferencesService prefs);
  Future<void> save(T value);

  PreferencesService get prefs => ref.read(preferencesServiceProvider);
  PedometerService get pedometer => ref.read(pedometerServiceProvider);

  @override
  T build() {
    _hydrate();
    return fallback;
  }

  Future<void> _hydrate() async => state = await load(prefs);

  Future<void> update(T value) async {
    state = value;
    await save(value);
  }
}

/// The user's configured daily step target (defaults to 10,000).
final dailyTargetProvider = NotifierProvider<DailyTargetNotifier, int>(
  DailyTargetNotifier.new,
);

class DailyTargetNotifier extends SettingNotifier<int> {
  @override
  int get fallback => PreferencesService.defaultDailyTarget;

  @override
  Future<int> load(PreferencesService prefs) => prefs.getDailyTarget();

  @override
  Future<void> save(int value) => pedometer.setDailyTarget(value);
}

final calibrationFactorProvider =
    NotifierProvider<CalibrationFactorNotifier, double>(
  CalibrationFactorNotifier.new,
);

class CalibrationFactorNotifier extends SettingNotifier<double> {
  @override
  double get fallback => PreferencesService.defaultCorrectionFactor;

  @override
  Future<double> load(PreferencesService prefs) => prefs.getCorrectionFactor();

  @override
  Future<void> save(double value) => pedometer.setCorrectionFactor(value);
}

/// The user's measured walking cadence. Unlike the calibration factor this
/// never leaves the app isolate — only the UI's metrics use it.
final stepsPerMinuteProvider =
    NotifierProvider<StepsPerMinuteNotifier, double>(
  StepsPerMinuteNotifier.new,
);

class StepsPerMinuteNotifier extends SettingNotifier<double> {
  @override
  double get fallback => StepMetrics.defaultStepsPerMinute;

  @override
  Future<double> load(PreferencesService prefs) => prefs.getStepsPerMinute();

  @override
  Future<void> save(double value) => prefs.setStepsPerMinute(value);
}

final heightCmProvider = NotifierProvider<HeightCmNotifier, double?>(
  HeightCmNotifier.new,
);

class HeightCmNotifier extends SettingNotifier<double?> {
  @override
  double? get fallback => null;

  @override
  Future<double?> load(PreferencesService prefs) => prefs.getHeightCm();

  @override
  Future<void> save(double? value) => prefs.setHeightCm(value);
}

final weightKgProvider = NotifierProvider<WeightKgNotifier, double?>(
  WeightKgNotifier.new,
);

class WeightKgNotifier extends SettingNotifier<double?> {
  @override
  double? get fallback => null;

  @override
  Future<double?> load(PreferencesService prefs) => prefs.getWeightKg();

  @override
  Future<void> save(double? value) => prefs.setWeightKg(value);
}

/// Which unit system to display values in throughout the app.
final unitSystemProvider = NotifierProvider<UnitSystemNotifier, UnitSystem>(
  UnitSystemNotifier.new,
);

class UnitSystemNotifier extends SettingNotifier<UnitSystem> {
  @override
  UnitSystem get fallback => UnitSystem.metric;

  @override
  Future<UnitSystem> load(PreferencesService prefs) => prefs.getUnitSystem();

  @override
  Future<void> save(UnitSystem value) => prefs.setUnitSystem(value);
}

/// Zero-filled past 7 days, chronological. Re-fetches on app start and
/// every 100 steps (not every step).
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
    final dateStr = dateKey(today.subtract(Duration(days: 6 - i)));
    return DailySteps(date: dateStr, stepCount: byDate[dateStr] ?? 0);
  });
});

final hourlyStepsForDateProvider =
    FutureProvider.autoDispose.family<List<HourlySteps>, String>(
  (ref, date) async {
    if (date == todayKey()) {
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

/// Marks a route currently in progress.
class ActiveRoute {
  final int routeId;
  final String routeName;
  final DateTime startTime;
  const ActiveRoute({
    required this.routeId,
    required this.routeName,
    required this.startTime,
  });
}

/// The route currently being tracked, or null. Persisted to survive an app
/// restart, and mirrored to the background service.
final activeRouteProvider =
    NotifierProvider<ActiveRouteNotifier, ActiveRoute?>(
  ActiveRouteNotifier.new,
);

class ActiveRouteNotifier extends Notifier<ActiveRoute?> {
  @override
  ActiveRoute? build() {
    _load();
    return null;
  }

  Future<void> _load() async {
    final saved = await ref.read(preferencesServiceProvider).getActiveRoute();
    if (saved == null) return;
    state = ActiveRoute(
      routeId: saved['routeId'] as int,
      routeName: saved['routeName'] as String,
      startTime: DateTime.parse(saved['startTime'] as String),
    );
  }

  Future<void> startRoute(int routeId, String routeName) async {
    // Drop any count left over from the previous route, so this one's first
    // subscriber isn't replayed the last walk's total.
    ref.read(pedometerServiceProvider).clearActiveRouteSteps();
    final startTime = DateTime.now();
    state = ActiveRoute(
      routeId: routeId,
      routeName: routeName,
      startTime: startTime,
    );
    channel.startRoute.send(
      FlutterBackgroundService(),
      channel.StartRoute(routeId: routeId, routeName: routeName),
    );
  }

  Future<void> stopRoute() async {
    state = null;
    ref.read(pedometerServiceProvider).clearActiveRouteSteps();
    // Cleared from both sides, unlike the write above. Clearing is
    // idempotent and can only end a route.
    await ref.read(preferencesServiceProvider).clearActiveRoute();
    channel.stopRoute.send(FlutterBackgroundService());
  }
}

/// Live active-route step count, from the background service's
/// `'routeUpdate'` broadcast. Keyed by start time so a new route session
/// gets a genuinely fresh subscription — AsyncValue otherwise carries the
/// previous session's count across a plain `ref.invalidate`.
final activeRouteStepsProvider =
    StreamProvider.autoDispose.family<int, DateTime>((ref, routeStartTime) {
  final service = ref.watch(pedometerServiceProvider);
  return service.activeRouteStepsStream;
});
