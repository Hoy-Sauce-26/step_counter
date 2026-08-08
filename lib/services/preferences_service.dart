import 'package:shared_preferences/shared_preferences.dart';

/// Wraps SharedPreferences for the app's simple settings (currently just
/// the daily step target).
class PreferencesService {
  static const _dailyTargetKey = 'dailyTarget';
  static const int defaultDailyTarget = 10000;

  Future<int> getDailyTarget() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_dailyTargetKey) ?? defaultDailyTarget;
  }

  Future<void> setDailyTarget(int target) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_dailyTargetKey, target);
  }
}
