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
}
