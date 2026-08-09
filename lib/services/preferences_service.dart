import 'package:shared_preferences/shared_preferences.dart';

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
}
