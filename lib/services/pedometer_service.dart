import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:permission_handler/permission_handler.dart';

import 'database_helper.dart';
import 'formatting.dart';
import 'preferences_service.dart';
import 'service_channel.dart' as channel;

/// The three permission outcomes the UI has to tell apart. [denied] can be
/// retried with a system dialog; [permanentlyDenied] can't — Android silently
/// no-ops the request, so the only route left is the app's settings page.
enum StepPermissionStatus { granted, denied, permanentlyDenied }

class PedometerService {
  StreamSubscription<dynamic>? _bgStepSubscription;
  StreamSubscription<dynamic>? _bgRawSubscription;
  StreamSubscription<dynamic>? _bgRouteSubscription;
  StreamSubscription<dynamic>? _bgSensorStatusSubscription;
  final _controller = StreamController<int>.broadcast();
  final _sensorAvailableController = StreamController<bool>.broadcast();
  final _rawCumulativeController = StreamController<int>.broadcast();
  final _routeStepsController = StreamController<int>.broadcast();
  final _dbHelper = DatabaseHelper.instance;
  final _prefsService = PreferencesService();

  bool _starting = false;
  int? _lastKnownRawSteps;
  bool? _sensorAvailable;
  int? _activeRouteSteps;
  String? _liveStepsDate;

  Stream<int> get todayStepsStream => _controller.stream;

  /// Live active-route step count
  Stream<int> get activeRouteStepsStream => Stream<int>.multi((controller) {
        final known = _activeRouteSteps;
        if (known != null) controller.add(known);
        final subscription = _routeStepsController.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
        controller.onCancel = subscription.cancel;
      });

  void _setActiveRouteSteps(int steps) {
    _activeRouteSteps = steps;
    _routeStepsController.add(steps);
  }

  /// Forgets the cached count so the next route can't replay this one's
  /// total to its first subscriber.
  void clearActiveRouteSteps() => _activeRouteSteps = null;

  /// [Stream.multi] rather than an `async*` generator because a generator's
  /// body doesn't run until a microtask after `listen()` — long enough to
  /// read a stale value and to drop reports arriving in between.
  Stream<bool> get sensorAvailableStream => Stream<bool>.multi((controller) {
        final known = _sensorAvailable;
        if (known != null) controller.add(known);
        final subscription = _sensorAvailableController.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
        controller.onCancel = subscription.cancel;
      });

  /// Records a sensor report. Visible for testing because the real callers
  /// — the background-service broadcast and the persisted seed — both live
  /// inside [start], which needs platform channels a unit test can't give it.
  @visibleForTesting
  void setSensorAvailable(bool available) {
    if (_sensorAvailable == available) return;
    _sensorAvailable = available;
    _sensorAvailableController.add(available);
  }

  Future<StepPermissionStatus> requestPermission() async {
    return _toStepPermissionStatus(
      await Permission.activityRecognition.request(),
    );
  }

  Future<StepPermissionStatus> permissionStatus() async {
    return _toStepPermissionStatus(
      await Permission.activityRecognition.status,
    );
  }

  StepPermissionStatus _toStepPermissionStatus(PermissionStatus status) {
    if (status.isGranted) return StepPermissionStatus.granted;
    if (status.isPermanentlyDenied) {
      return StepPermissionStatus.permanentlyDenied;
    }
    return StepPermissionStatus.denied;
  }

  /// Opens this app's page in the OS settings — the only way back once a
  /// permission is permanently denied.
  Future<bool> openPermissionSettings() => openAppSettings();

  Future<bool> hasPermission() async {
    return Permission.activityRecognition.isGranted;
  }

  Future<void> start() async {
    if (_bgStepSubscription != null || _starting) return;
    _starting = true;

    // try/finally so a throw can't leave _starting stuck true. It would
    // block every later call permanently: _bgStepSubscription stays null on
    // the failure path, so the guard above can never clear itself.
    try {
      final granted = await hasPermission();
      if (!granted) {
        debugPrint('[PedometerService] start() called without permission '
            'granted yet — skipping for now.');
        return;
      }

      final today = todayKey();
      final existing = await _dbHelper.getStepsForDate(today);
      _controller.add(existing?.stepCount ?? 0);

      final service = FlutterBackgroundService();

      // TEMP DIAGNOSTIC — see BackgroundService.onServiceStart.
      if (kDebugMode) {
        debugPrint('[PedometerService] SUBSCRIBING to stepUpdate');
      }
      _bgStepSubscription = channel.stepUpdate.listen(service, (update) {
        _liveStepsDate = update.date;
        debugPrint('[PedometerService] stepUpdate from background service: '
            '${update.steps} at ${DateTime.now()}');
        _controller.add(update.steps);
      });

      _bgRawSubscription = channel.rawStep.listen(service, (raw) {
        _lastKnownRawSteps = raw;
        _rawCumulativeController.add(raw);
      });

      _bgRouteSubscription =
          channel.routeUpdate.listen(service, _setActiveRouteSteps);

      _bgSensorStatusSubscription =
          channel.sensorStatus.listen(service, setSensorAvailable);

      // Both reads below are of keys the service isolate owns — reload or
      // this answers from a stale start-up snapshot.
      await _prefsService.reload();

      // A route in progress across an app restart has no live broadcast to
      // catch up on — the service only emits on a reading.
      final savedRoute = await _prefsService.getActiveRoute();
      final savedRouteSteps = savedRoute?['steps'] as int?;
      if (savedRouteSteps != null && _activeRouteSteps == null) {
        _setActiveRouteSteps(savedRouteSteps);
      }

      final knownAvailable = await _prefsService.getStepSensorAvailable();
      if (knownAvailable != null && _sensorAvailable == null) {
        setSensorAvailable(knownAvailable);
      }

    } finally {
      _starting = false;
    }
  }

  /// Re-seeds the displayed count from storage on resume, so a date rollover
  /// while the app was away doesn't ever leave yesterday's total on screen.
  Future<void> refreshForCurrentDate() async {
    final today = todayKey();
    final existing = await _dbHelper.getStepsForDate(today);
    if (_liveStepsDate == today) return;
    _controller.add(existing?.stepCount ?? 0);
  }

  Future<void> setCorrectionFactor(double factor) async {
    await _prefsService.setCorrectionFactor(factor);
    // The background service caches its own copy — without this it
    // wouldn't pick up a recalibration until the next day or a restart.
    channel.setCorrectionFactor.send(FlutterBackgroundService(), factor);
  }

  Future<void> addManualSteps(int amount) async {
    channel.addManualSteps.send(FlutterBackgroundService(), amount);
  }

  Future<void> setDailyTarget(int target) async {
    await _prefsService.setDailyTarget(target);
    // Same reason as setCorrectionFactor
    channel.setDailyTarget.send(FlutterBackgroundService(), target);
  }

  void stop() {
    _bgStepSubscription?.cancel();
    _bgStepSubscription = null;
    _bgRawSubscription?.cancel();
    _bgRawSubscription = null;
    _bgRouteSubscription?.cancel();
    _bgRouteSubscription = null;
    _bgSensorStatusSubscription?.cancel();
    _bgSensorStatusSubscription = null;
  }

  void dispose() {
    stop();
    _controller.close();
    _rawCumulativeController.close();
    _routeStepsController.close();
    _sensorAvailableController.close();
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

}
