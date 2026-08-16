import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'metrics.dart';

/// Wraps SharedPreferences for the app's settings (target, calibration,
/// personalization, unit system).
class PreferencesService {
  static const _dailyTargetKey = 'dailyTarget';
  static const _correctionFactorKey = 'stepCorrectionFactor';
  static const int defaultDailyTarget = 10000;

  /// 1.0 = trust the sensor as-is; e.g. 0.93 scales readings down 7%.
  static const double defaultCorrectionFactor = 1.0;

  Future<int> getDailyTarget() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_dailyTargetKey) ?? defaultDailyTarget;
  }

  Future<void> setDailyTarget(int target) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_dailyTargetKey, target);
  }

  Future<double> getCorrectionFactor() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_correctionFactorKey) ?? defaultCorrectionFactor;
  }

  Future<void> setCorrectionFactor(double factor) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_correctionFactorKey, factor);
  }

  static const _lastRawStepsKey = 'lastRawSteps';

  Future<int?> getLastRawSteps() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_lastRawStepsKey);
  }

  Future<void> setLastRawSteps(int rawCumulative) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastRawStepsKey, rawCumulative);
  }

  /// The raw-sensor reading that counts as zero steps for [date]. Only the
  /// current day's is ever needed, so writing one drops every other day's.
  Future<int?> getStepBaseline(String date) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('baseline_$date');
  }

  Future<void> setStepBaseline(String date, int baseline) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'baseline_$date';
    await prefs.setInt(key, baseline);
    final stale = prefs
        .getKeys()
        .where((k) => k.startsWith('baseline_') && k != key)
        .toList();
    for (final k in stale) {
      await prefs.remove(k);
    }
  }

  // Written by the background isolate — the only place allowed to touch the
  // sensor — and read by the app at launch.
  static const _stepSensorAvailableKey = 'stepSensorAvailable';

  Future<bool?> getStepSensorAvailable() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_stepSensorAvailableKey);
  }

  Future<void> setStepSensorAvailable(bool available) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_stepSensorAvailableKey, available);
  }

  // Nullable/unset by default — StepMetrics falls back to flat-rate
  // constants when missing, so personalization is opt-in.
  static const _heightCmKey = 'heightCm';
  static const _weightKgKey = 'weightKg';

  Future<double?> getHeightCm() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_heightCmKey)
        ? prefs.getDouble(_heightCmKey)
        : null;
  }

  Future<void> setHeightCm(double? cm) async {
    final prefs = await SharedPreferences.getInstance();
    if (cm == null) {
      await prefs.remove(_heightCmKey);
    } else {
      await prefs.setDouble(_heightCmKey, cm);
    }
  }

  Future<double?> getWeightKg() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_weightKgKey)
        ? prefs.getDouble(_weightKgKey)
        : null;
  }

  Future<void> setWeightKg(double? kg) async {
    final prefs = await SharedPreferences.getInstance();
    if (kg == null) {
      await prefs.remove(_weightKgKey);
    } else {
      await prefs.setDouble(_weightKgKey, kg);
    }
  }

  static const _unitSystemKey = 'unitSystem';

  Future<UnitSystem> getUnitSystem() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_unitSystemKey);
    return raw == 'imperial' ? UnitSystem.imperial : UnitSystem.metric;
  }

  Future<void> setUnitSystem(UnitSystem system) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _unitSystemKey,
      system == UnitSystem.imperial ? 'imperial' : 'metric',
    );
  }

  // One JSON blob, not separate keys — one active route (or none) should
  // read/clear atomically.
  static const _activeRouteKey = 'activeRoute';

  /// [rawBaseline] is the raw sensor reading this route's current segment
  /// counts from. [stepsBefore] is what earlier segments contributed, and
  /// [steps] is the running total — kept so a reboot, which zeroes the
  /// hardware counter and takes the service isolate with it, can pick the
  /// route back up instead of restarting it at nothing.
  Future<void> setActiveRoute({
    required int routeId,
    required String routeName,
    required DateTime startTime,
    int? rawBaseline,
    int stepsBefore = 0,
    int steps = 0,
    int? lastRaw,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _activeRouteKey,
      jsonEncode({
        'routeId': routeId,
        'routeName': routeName,
        'startTime': startTime.toIso8601String(),
        'rawBaseline': rawBaseline,
        'stepsBefore': stepsBefore,
        'steps': steps,
        'lastRaw': lastRaw,
      }),
    );
  }

  /// {routeId, routeName, startTime, rawBaseline}, or null if none active.
  Future<Map<String, dynamic>?> getActiveRoute() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_activeRouteKey);
    if (raw == null) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> clearActiveRoute() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_activeRouteKey);
  }

  /// Steps manually credited to [date] (e.g. a route logged without live
  /// tracking), on top of whatever the sensor recorded. Defaults to 0.
  Future<int> getManualSteps(String date) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('manualSteps_$date') ?? 0;
  }

  Future<void> setManualSteps(String date, int steps) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('manualSteps_$date', steps);
  }
}
