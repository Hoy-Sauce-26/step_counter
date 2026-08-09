import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/daily_steps.dart';
import 'database_helper.dart';
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

/// 'walking' / 'stopped' / 'unknown' — a faster-reacting motion signal,
/// separate from the (batched, slower-to-update) step counter. Used only
/// to give the UI something to show while the counter is still warming up.
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

/// Zero-filled list of the past 7 days' records, chronological.
/// Re-fetches whenever today's live step count changes.
final past7DaysProvider =
    FutureProvider.autoDispose<List<DailySteps>>((ref) async {
  ref.watch(todayStepsProvider); // re-fetch on new sensor readings
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

final currentMonthRecordsProvider =
    FutureProvider.autoDispose<List<DailySteps>>((ref) async {
  ref.watch(todayStepsProvider);
  final db = ref.watch(databaseHelperProvider);
  final now = DateTime.now();
  return db.getRecordsForMonth(now.year, now.month);
});

final yearlyMonthlyTotalsProvider =
    FutureProvider.autoDispose<Map<int, int>>((ref) async {
  ref.watch(todayStepsProvider);
  final db = ref.watch(databaseHelperProvider);
  return db.getMonthlyTotalsForYear(DateTime.now().year);
});
