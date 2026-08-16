import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';

import 'database_helper.dart';
import 'notification_service.dart';
import 'preferences_service.dart';

class PedometerService {
  StreamSubscription<PedestrianStatus>? _statusSubscription;
  StreamSubscription<dynamic>? _bgStepSubscription;
  StreamSubscription<dynamic>? _bgRawSubscription;
  StreamSubscription<dynamic>? _bgRouteSubscription;
  final _controller = StreamController<int>.broadcast();
  final _statusController = StreamController<String>.broadcast();
  final _rawCumulativeController = StreamController<int>.broadcast();
  final _routeStepsController = StreamController<int>.broadcast();
  final _dbHelper = DatabaseHelper.instance;
  final _prefsService = PreferencesService();

  bool _starting = false;
  int? _lastKnownRawSteps;

  Stream<int> get todayStepsStream => _controller.stream;

  Stream<String> get walkingStatusStream => _statusController.stream;

  /// Live active-route step count, relayed from the background service's
  /// `'routeUpdate'` broadcast.
  Stream<int> get activeRouteStepsStream => _routeStepsController.stream;

  Future<bool> requestPermission() async {
    final status = await Permission.activityRecognition.request();
    return status.isGranted;
  }

  Future<bool> hasPermission() async {
    return Permission.activityRecognition.isGranted;
  }

  Future<void> start() async {
    if (_bgStepSubscription != null || _starting) return;
    _starting = true;

    final granted = await hasPermission();
    if (!granted) {
      debugPrint('[PedometerService] start() called without permission '
          'granted yet — skipping for now.');
      _starting = false;
      return;
    }

    final today = _todayString();
    final existing = await _dbHelper.getStepsForDate(today);
    _controller.add(existing?.stepCount ?? 0);

    final service = FlutterBackgroundService();

    _bgStepSubscription = service.on('stepUpdate').listen((event) {
      if (event == null) return;
      final steps = event['steps'] as int? ?? 0;
      debugPrint('[PedometerService] stepUpdate from background service: '
          '$steps at ${DateTime.now()}');
      _controller.add(steps);
    });

    _bgRawSubscription = service.on('rawStep').listen((event) {
      if (event == null) return;
      final raw = event['raw'] as int? ?? 0;
      _lastKnownRawSteps = raw;
      _rawCumulativeController.add(raw);
    });

    _bgRouteSubscription = service.on('routeUpdate').listen((event) {
      if (event == null) return;
      final steps = event['steps'] as int? ?? 0;
      _routeStepsController.add(steps);
    });

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

  Future<void> refreshForCurrentDate() async {
    final today = _todayString();
    final existing = await _dbHelper.getStepsForDate(today);
    _controller.add(existing?.stepCount ?? 0);
  }

  Future<void> setCorrectionFactor(double factor) async {
    await _prefsService.setCorrectionFactor(factor);
    // The background service caches its own copy — without this it
    // wouldn't pick up a recalibration until the next day or a restart.
    FlutterBackgroundService().invoke('setCorrectionFactor', {'factor': factor});
  }

  Future<void> setDailyTarget(int target) async {
    await _prefsService.setDailyTarget(target);
    // Same reason as setCorrectionFactor
    FlutterBackgroundService().invoke('setDailyTarget', {'target': target});
  }

  Future<void> refreshNotificationWithTarget(
    int target,
    int currSteps,
  ) async {
    await NotificationService.updateStepNotification(
      steps: currSteps,
      target: target,
    );
  }

  void stop() {
    _bgStepSubscription?.cancel();
    _bgStepSubscription = null;
    _bgRawSubscription?.cancel();
    _bgRawSubscription = null;
    _bgRouteSubscription?.cancel();
    _bgRouteSubscription = null;
    _statusSubscription?.cancel();
    _statusSubscription = null;
  }

  void dispose() {
    stop();
    _controller.close();
    _statusController.close();
    _rawCumulativeController.close();
    _routeStepsController.close();
  }

  StreamSubscription<int> startCalibrationTest(
    void Function(int rawSteps) onUpdate,
  ) {
    // Seed from the last known reading — waiting for the next event to
    // define the baseline would absorb that event's own step, undercounting
    // by one. Falls back to that lazy behavior only if nothing's arrived yet.
    int? testBaseline = _lastKnownRawSteps;
    return _rawCumulativeController.stream.listen((rawCumulative) {
      testBaseline ??= rawCumulative;
      onUpdate((rawCumulative - testBaseline!).clamp(0, 1 << 30));
    });
  }

  String _todayString() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }
}
