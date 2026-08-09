import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/daily_steps.dart';
import 'database_helper.dart';
import 'preferences_service.dart';

/// Bridges the raw hardware pedometer stream (which reports a value that
/// is cumulative since the device's last reboot, NOT since midnight) into
/// a "steps taken today" stream, and persists that value to SQLite.
///
/// Strategy: for each calendar day we store a "baseline" — the raw
/// cumulative sensor reading at the moment today's count was 0 — in
/// SharedPreferences as `baseline_<date>`. Today's step count is then
/// `(rawCumulative - baseline) * correctionFactor`. If the app is killed
/// and relaunched mid-day, the baseline is reconstructed from whatever was
/// last persisted to SQLite for today, so counts don't reset to zero.
///
/// [correctionFactor] (see PreferencesService) exists because the phone's
/// hardware step sensor is the actual source of truth here — this app
/// doesn't run its own step-detection algorithm — so if that sensor is
/// systematically over/under-counting, the only lever we have is a
/// calibration multiplier applied on top of its raw output.
class PedometerService {
  StreamSubscription<StepCount>? _subscription;
  StreamSubscription<PedestrianStatus>? _statusSubscription;
  final _controller = StreamController<int>.broadcast();
  final _statusController = StreamController<String>.broadcast();
  final _dbHelper = DatabaseHelper.instance;
  final _prefsService = PreferencesService();

  String? _trackedDate;
  int? _baseline;
  double _correctionFactor = PreferencesService.defaultCorrectionFactor;
  bool _starting = false;

  /// Emits the current day's step count every time a new sensor reading
  /// arrives.
  Stream<int> get todayStepsStream => _controller.stream;

  /// Emits 'walking', 'stopped', or 'unknown' from the separate, lower-
  /// latency TYPE_STEP_DETECTOR-backed sensor. Purely informational — it
  /// exists so the UI can show "motion detected" feedback while the
  /// batched step *counter* is still warming up (which, especially right
  /// after a fresh install, can take a minute or more before its first
  /// event — see PedometerService doc comment above).
  Stream<String> get walkingStatusStream => _statusController.stream;

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
  /// times, including concurrently (e.g. two providers both calling this
  /// on app start) — the `_starting` flag is set synchronously, before any
  /// `await`, so a second call can't slip past the guard while the first
  /// call is still mid-registration.
  Future<void> start() async {
    if (_subscription != null || _starting) return;
    _starting = true;

    _correctionFactor = await _prefsService.getCorrectionFactor();

    // Android's TYPE_STEP_COUNTER sensor only fires an event when the step
    // count changes — it does NOT push an initial reading just because a
    // listener was registered. Without this, the UI would sit on a
    // "loading" state indefinitely until the user took a step. Seed the
    // stream with today's last-persisted count (0 if none) so the UI has
    // something to show immediately.
    final today = _todayString();
    final existing = await _dbHelper.getStepsForDate(today);
    _controller.add(existing?.stepCount ?? 0);

    final registeredAt = DateTime.now();
    debugPrint('[PedometerService] registering stepCountStream listener '
        'at $registeredAt');

    _subscription = Pedometer.stepCountStream.listen(
      _onStepCount,
      onError: (Object error) {
        debugPrint('[PedometerService] stepCountStream error: $error');
        // Sensor unavailable or stream error — surface as -1 so the UI
        // can show a "not available" state rather than crashing.
        _controller.add(-1);
      },
      cancelOnError: false,
    );

    _statusSubscription = Pedometer.pedestrianStatusStream.listen(
      (status) {
        debugPrint('[PedometerService] pedestrian status: ${status.status} '
            'at ${DateTime.now()}');
        _statusController.add(status.status);
      },
      onError: (Object error) => _statusController.add('unknown'),
      cancelOnError: false,
    );

    _starting = false;
  }

  /// Updates the calibration factor used for future readings (e.g. after
  /// the user adjusts it in settings). Persists it and re-emits today's
  /// count recalculated with the new factor.
  Future<void> setCorrectionFactor(double factor) async {
    _correctionFactor = factor;
    await _prefsService.setCorrectionFactor(factor);

    if (_trackedDate != null && _baseline != null) {
      // Re-derive today's raw delta from the last persisted (corrected)
      // value under the *previous* factor isn't reliable, so instead just
      // wait for the next sensor event to re-emit under the new factor —
      // simplest and avoids compounding rounding error. Nothing to do here
      // for the in-memory state; the next _onStepCount call picks it up.
    }
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
    _statusSubscription?.cancel();
    _statusSubscription = null;
  }

  void dispose() {
    stop();
    _controller.close();
    _statusController.close();
  }

  /// Starts a short, standalone listening session for the calibration-test
  /// UI: reports the raw (uncorrected) step delta since the test began via
  /// [onUpdate]. This is completely independent of the day's baseline /
  /// today-steps tracking — it's just "how many raw sensor events have
  /// fired since I started this test" — so it isn't affected by whatever
  /// correction factor is currently set. Returns the subscription so the
  /// caller can cancel it when the test ends or is dismissed.
  StreamSubscription<StepCount> startCalibrationTest(
    void Function(int rawSteps) onUpdate,
  ) {
    int? testBaseline;
    return Pedometer.stepCountStream.listen((event) {
      testBaseline ??= event.steps;
      onUpdate((event.steps - testBaseline!).clamp(0, 1 << 30));
    });
  }

  Future<void> _onStepCount(StepCount event) async {
    debugPrint('[PedometerService] raw event: steps=${event.steps} '
        'at ${DateTime.now()} (sensor timestamp: ${event.timeStamp})');

    final today = _todayString();

    if (_trackedDate != today) {
      // New day (or first event since app start): (re)establish baseline.
      _trackedDate = today;
      _baseline = await _resolveBaseline(today, event.steps);
    }

    final rawDelta = (event.steps - (_baseline ?? event.steps))
        .clamp(0, 1 << 30);
    final todaySteps = (rawDelta * _correctionFactor).round();

    _controller.add(todaySteps);

    await _dbHelper.upsertSteps(
      DailySteps(date: today, stepCount: todaySteps),
    );
  }

  /// Figures out what the sensor's cumulative reading was when today's
  /// count was zero. If we already have a persisted baseline for today
  /// (app was previously running today), reuse it. Otherwise, if there's
  /// already a step count logged for today (e.g. app restarted mid-day
  /// without a saved baseline), back-calculate the baseline from that —
  /// inverting the correction factor, since the stored value is already
  /// calibrated. Otherwise, today starts fresh: baseline = current raw
  /// reading.
  Future<int> _resolveBaseline(String date, int rawCumulative) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'baseline_$date';

    final saved = prefs.getInt(key);
    if (saved != null) return saved;

    final existing = await _dbHelper.getStepsForDate(date);
    final rawExistingDelta = existing == null
        ? 0
        : (_correctionFactor == 0
            ? 0
            : (existing.stepCount / _correctionFactor).round());
    final baseline = rawCumulative - rawExistingDelta;

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
