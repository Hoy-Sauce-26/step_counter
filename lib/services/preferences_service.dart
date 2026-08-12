import 'package:shared_preferences/shared_preferences.dart';

import 'metrics.dart';

/// Wraps SharedPreferences for the app's simple settings (daily step
/// target and the step-count calibration factor).
class PreferencesService {
  static const _dailyTargetKey = 'dailyTarget';
  static const _correctionFactorKey = 'stepCorrectionFactor';
  static const int defaultDailyTarget = 10000;

  /// 1.0 = trust the sensor as-is. 0.93, for example, scales every raw
  /// reading down by 7% to correct for a sensor that's overcounting.
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

  // Height/weight are nullable and unset by default — StepMetrics falls
  // back to its flat-rate constants when either is missing, so
  // personalization is opt-in, not required.
  static const _heightInchesKey = 'heightInches';
  static const _weightKgKey = 'weightKg';

  Future<double?> getHeightInches() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_heightInchesKey)
        ? prefs.getDouble(_heightInchesKey)
        : null;
  }

  Future<void> setHeightInches(double? inches) async {
    final prefs = await SharedPreferences.getInstance();
    if (inches == null) {
      await prefs.remove(_heightInchesKey);
    } else {
      await prefs.setDouble(_heightInchesKey, inches);
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

  // Which unit system to DISPLAY values in. Stored data (height in
  // inches, weight in kg) never changes based on this — it's purely a
  // display/input preference, applied wherever values are shown or typed.
  static const _unitSystemKey = 'unitSystem';
  static const UnitSystem defaultUnitSystem = UnitSystem.imperial;

  Future<UnitSystem> getUnitSystem() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_unitSystemKey);
    return raw == 'metric' ? UnitSystem.metric : UnitSystem.imperial;
  }

  Future<void> setUnitSystem(UnitSystem system) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _unitSystemKey,
      system == UnitSystem.metric ? 'metric' : 'imperial',
    );
  }
}
