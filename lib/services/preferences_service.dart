import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import 'metrics.dart';

/// Wraps SharedPreferences for the app's settings (target, calibration,
/// personalization, unit system).
class PreferencesService {
  static const _dailyTargetKey = 'dailyTarget';
  static const _correctionFactorKey = 'stepCorrectionFactor';
  static const int defaultDailyTarget = 10000;

  static const double defaultCorrectionFactor = 1.0;
  static const double minCorrectionFactor = 0.9;
  static const double maxCorrectionFactor = 1.1;

  // 60 is an amble, 150 is a near-jog. A stored value outside that came from
  // a miscounted test, not a walker, so it is clamped rather than trusted.
  static const double minStepsPerMinute = 60;
  static const double maxStepsPerMinute = 150;

  /// Removes keys left behind by storage this version no longer uses.
  ///
  /// Baselines and last-raw readings were how totals were derived before the
  /// journal; nothing reads them now. Preferences load whole on first access,
  /// so orphans are paid for on every launch until they are cleared.
  Future<void> removeSupersededKeys() async {
    final prefs = await SharedPreferences.getInstance();
    const dead = {
      'lastRawReading',
      'lastRawSteps',
      'lastRawStepsAt',
      'roameterLastRawReading',
    };
    final stale = prefs.getKeys().where((key) {
      final name = key.startsWith('flutter.') ? key.substring(8) : key;
      return dead.contains(name) ||
          name.startsWith('baseline_') ||
          name.startsWith('roameter_baseline_');
    }).toList();

    for (final key in stale) {
      await prefs.remove(key.startsWith('flutter.') ? key.substring(8) : key);
    }
  }

  /// Drops this isolate's cached snapshot of the preference file, so a
  /// value the other isolate just wrote becomes visible here.
  Future<void> reload() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
  }

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

  static const _stepsPerMinuteKey = 'stepsPerMinute';

  /// The user's measured walking cadence. Drives active time directly and
  /// calories through walking speed — see [StepMetrics.speedKmh]. App-side
  /// only: the service isolate has no use for it, so unlike the correction
  /// factor it needs no mirroring.
  Future<double> getStepsPerMinute() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getDouble(_stepsPerMinuteKey);
    if (stored == null) return StepMetrics.defaultStepsPerMinute;
    return stored.clamp(minStepsPerMinute, maxStepsPerMinute);
  }

  Future<void> setStepsPerMinute(double stepsPerMinute) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(
      _stepsPerMinuteKey,
      stepsPerMinute.clamp(minStepsPerMinute, maxStepsPerMinute),
    );
  }

  // Whether the always-on foreground service runs. Off means no ongoing
  // notification and no live updates; steps are still counted, because the
  // hardware counter never stopped and the journal picks the gap up. On by
  // default — a live count is the thing the app is for.
  static const _foregroundTrackingKey = 'foregroundTrackingEnabled';

  Future<bool> getForegroundTrackingEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_foregroundTrackingKey) ?? true;
  }

  Future<void> setForegroundTrackingEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_foregroundTrackingKey, enabled);
  }

  // Written by the background isolate on a timer, not per-reading — a
  // reading's own timestamp can't distinguish "asleep for 8h" from "dead".
  static const _serviceHeartbeatKey = 'serviceHeartbeat';

  Future<DateTime?> getServiceHeartbeat() async {
    final prefs = await SharedPreferences.getInstance();
    final millis = prefs.getInt(_serviceHeartbeatKey);
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  Future<void> setServiceHeartbeat(DateTime at) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_serviceHeartbeatKey, at.millisecondsSinceEpoch);
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

  // Set once the reader waves away the battery-exemption prompt, so it
  // doesn't nag; the Settings screen still offers it.
  static const _batteryPromptDismissedKey = 'batteryPromptDismissed';

  Future<bool> getBatteryPromptDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_batteryPromptDismissedKey) ?? false;
  }

  Future<void> setBatteryPromptDismissed(bool dismissed) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_batteryPromptDismissedKey, dismissed);
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

  /// A manual credit left over from before credits became per-date database
  /// rows. Read once at start-up by [StepProjection] and then cleared; new
  /// credits never come here.
  Future<int> getManualSteps(String date) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('manualSteps_$date') ?? 0;
  }

  /// Only the current day's credit is ever read, so writing one drops every
  /// other day's — same reasoning as [setStepBaseline].
  /// Clears a legacy credit once it has been moved into the database.
  Future<void> clearManualSteps(String date) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('manualSteps_$date');
  }

  /// Legacy: nothing in the app writes credits here any more. Kept so the
  /// migration in `StepProjection` has something to exercise in tests.
  @visibleForTesting
  Future<void> setManualSteps(String date, int steps) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'manualSteps_$date';
    await prefs.setInt(key, steps);
    final stale = prefs
        .getKeys()
        .where((k) => k.startsWith('manualSteps_') && k != key)
        .toList();
    for (final k in stale) {
      await prefs.remove(k);
    }
  }
}
