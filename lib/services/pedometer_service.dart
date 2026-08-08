import 'dart:async';

import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/daily_steps.dart';
import 'database_helper.dart';

/// Bridges the raw hardware pedometer stream (which reports a value that
/// is cumulative since the device's last reboot, NOT since midnight) into
/// a "steps taken today" stream, and persists that value to SQLite.
///
/// Strategy: for each calendar day we store a "baseline" — the raw
/// cumulative sensor reading at the moment today's count was 0 — in
/// SharedPreferences as `baseline_<date>`. Today's step count is then
/// `rawCumulative - baseline`. If the app is killed and relaunched mid-day,
/// the baseline is reconstructed from whatever was last persisted to
/// SQLite for today, so counts don't reset to zero.
class PedometerService {
  StreamSubscription<StepCount>? _subscription;
  final _controller = StreamController<int>.broadcast();
  final _dbHelper = DatabaseHelper.instance;

  String? _trackedDate;
  int? _baseline;

  /// Emits the current day's step count every time a new sensor reading
  /// arrives.
  Stream<int> get todayStepsStream => _controller.stream;

  /// Requests the ACTIVITY_RECOGNITION (Android) / Motion & Fitness (iOS)
  /// permission. Returns true if granted.
  Future<bool> requestPermission() async {
    final status = await Permission.activityRecognition.request();
    return status.isGranted;
  }

  Future<bool> hasPermission() async {
    return Permission.activityRecognition.isGranted;
  }

  /// Begins listening to the hardware pedometer. Safe to call multiple
  /// times; subsequent calls are ignored while already listening.
  Future<void> start() async {
    if (_subscription != null) return;

    _subscription = Pedometer.stepCountStream.listen(
      _onStepCount,
      onError: (Object error) {
        // Sensor unavailable or stream error — surface as -1 so the UI
        // can show a "not available" state rather than crashing.
        _controller.add(-1);
      },
      cancelOnError: false,
    );
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
  }

  void dispose() {
    stop();
    _controller.close();
  }

  Future<void> _onStepCount(StepCount event) async {
    final today = _todayString();

    if (_trackedDate != today) {
      // New day (or first event since app start): (re)establish baseline.
      _trackedDate = today;
      _baseline = await _resolveBaseline(today, event.steps);
    }

    final todaySteps = (event.steps - (_baseline ?? event.steps))
        .clamp(0, 1 << 30);

    _controller.add(todaySteps);

    await _dbHelper.upsertSteps(
      DailySteps(date: today, stepCount: todaySteps),
    );
  }

  /// Figures out what the sensor's cumulative reading was when today's
  /// count was zero. If we already have a persisted baseline for today
  /// (app was previously running today), reuse it. Otherwise, if there's
  /// already a step count logged for today (e.g. app restarted mid-day
  /// without a saved baseline), back-calculate the baseline from that.
  /// Otherwise, today starts fresh: baseline = current raw reading.
  Future<int> _resolveBaseline(String date, int rawCumulative) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'baseline_$date';

    final saved = prefs.getInt(key);
    if (saved != null) return saved;

    final existing = await _dbHelper.getStepsForDate(date);
    final baseline = rawCumulative - (existing?.stepCount ?? 0);

    await prefs.setInt(key, baseline);
    // Clean up baselines from previous days to avoid unbounded growth.
    await _pruneOldBaselines(prefs, keep: date);

    return baseline;
  }

  Future<void> _pruneOldBaselines(
    SharedPreferences prefs, {
    required String keep,
  }) async {
    final keysToRemove = prefs
        .getKeys()
        .where((k) => k.startsWith('baseline_') && k != 'baseline_$keep');
    for (final k in keysToRemove) {
      await prefs.remove(k);
    }
  }

  String _todayString() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }
}
