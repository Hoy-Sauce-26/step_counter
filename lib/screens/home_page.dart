import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/metrics.dart';
import '../services/pedometer_service.dart';
import '../services/providers.dart';
import '../widgets/calibration_dialog.dart';
import '../widgets/charts/weekly_bar_chart.dart';
import '../widgets/edit_target_dialog.dart';
import '../widgets/hourly_breakdown_dialog.dart';
import '../widgets/metric_card.dart';
import '../widgets/personalize_dialog.dart';
import '../widgets/step_progress_ring.dart';
import 'routes_page.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage>
    with WidgetsBindingObserver {
  /// Null until the first check completes.
  StepPermissionStatus? _permission;

  bool get _permissionGranted => _permission == StepPermissionStatus.granted;

  // Guards the overlapping start attempts visible in the service logs: the
  // resume handler and the permission flow both call in, and the await
  // inside gives each a window to see "not running" as well.
  bool _ensuringBackgroundService = false;
  bool _backgroundServiceFailed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensurePermission());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Re-sync on resume, so a date rollover while the app was closed
      // doesn't leave yesterday's total on screen until the next step.
      ref.read(pedometerServiceProvider).refreshForCurrentDate();

      // Without this the denied screen stays up until the app is restarted.
      _refreshPermissionStatus();

      // Restart the background service if something killed it (OEM
      // battery manager, etc.) instead of tracking staying off silently.
      _ensureBackgroundServiceRunning();
    }
  }

  Future<void> _ensureBackgroundServiceRunning() async {
    if (!_permissionGranted || _ensuringBackgroundService) return;
    _ensuringBackgroundService = true;
    try {
      final bgService = FlutterBackgroundService();
      final isRunning = await bgService.isRunning();
      if (!isRunning) {
        await bgService.startService();
      }
      if (mounted && _backgroundServiceFailed) {
        setState(() => _backgroundServiceFailed = false);
      }
    } catch (error, stackTrace) {
      debugPrint('[HomePage] Failed to start background service: $error\n'
          '$stackTrace');
      if (mounted) {
        setState(() => _backgroundServiceFailed = true);
      }
    } finally {
      _ensuringBackgroundService = false;
    }
  }

  Future<void> _ensurePermission() async {
    final service = ref.read(pedometerServiceProvider);
    var status = await service.permissionStatus();
    if (status != StepPermissionStatus.granted) {
      status = await service.requestPermission();
    }
    await _applyPermissionStatus(status);
  }

  /// Re-reads the status without prompting. Called on resume, so returning
  /// from the settings page takes effect immediately.
  Future<void> _refreshPermissionStatus() async {
    final status = await ref.read(pedometerServiceProvider).permissionStatus();
    if (status == _permission) return;
    await _applyPermissionStatus(status);
  }

  Future<void> _applyPermissionStatus(StepPermissionStatus status) async {
    if (!mounted) return;
    setState(() => _permission = status);
    if (status != StepPermissionStatus.granted) return;

    // service.start() already ran once on first build, before permission was
    // granted, so it bailed out.
    await ref.read(pedometerServiceProvider).start();
    await _ensureBackgroundServiceRunning();
  }

  Future<void> _openPermissionSettings() async {
    await ref.read(pedometerServiceProvider).openPermissionSettings();
  }

  Widget _body({
    required AsyncValue<int> stepsAsync,
    required int target,
    required String? walkingStatus,
    required double? heightCm,
    required double? weightKg,
    required UnitSystem unitSystem,
    required bool? sensorAvailable,
  }) {
    switch (_permission) {
      case null:
        return const Center(child: CircularProgressIndicator());
      case StepPermissionStatus.permanentlyDenied:
        return _PermissionBlocked(onOpenSettings: _openPermissionSettings);
      case StepPermissionStatus.denied:
        return _PermissionDenied(onRetry: _ensurePermission);
      case StepPermissionStatus.granted:
        break;
    }

    if (sensorAvailable == false) return const _SensorUnavailable();

    final content = stepsAsync.when(
      data: (steps) => _StepContent(
        steps: steps,
        target: target,
        walkingStatus: walkingStatus,
        heightCm: heightCm,
        weightKg: weightKg,
        unitSystem: unitSystem,
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, st) => Center(child: Text('Sensor error: $err')),
    );
    if (!_backgroundServiceFailed) return content;

    // Sits above the counts rather than replacing them: the stored total is
    // still real and worth showing, it just isn't advancing.
    return Column(
      children: [
        _BackgroundServiceFailedBanner(
          onRetry: _ensureBackgroundServiceRunning,
        ),
        Expanded(child: content),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final target = ref.watch(dailyTargetProvider);
    final calibrationFactor = ref.watch(calibrationFactorProvider);
    final heightCm = ref.watch(heightCmProvider);
    final weightKg = ref.watch(weightKgProvider);
    final unitSystem = ref.watch(unitSystemProvider);
    final stepsAsync = ref.watch(todayStepsProvider);
    final walkingStatus = ref.watch(walkingStatusProvider).value;
    final sensorAvailable = ref.watch(stepSensorAvailableProvider).value;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Roamfree'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_outline),
            tooltip: 'Personalize',
            onPressed: () async {
              final result = await showPersonalizeDialog(
                context,
                currentHeightCm: heightCm,
                currentWeightKg: weightKg,
                currentUnitSystem: unitSystem,
              );
              if (result != null) {
                ref
                    .read(heightCmProvider.notifier)
                    .setHeight(result.heightCm);
                ref
                    .read(weightKgProvider.notifier)
                    .setWeight(result.weightKg);
                ref
                    .read(unitSystemProvider.notifier)
                    .setSystem(result.unitSystem);
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'Calibrate step count',
            onPressed: () async {
              final pedometerService = ref.read(pedometerServiceProvider);
              final newFactor = await showCalibrationDialog(
                context,
                calibrationFactor,
                pedometerService,
              );
              if (newFactor != null) {
                ref
                    .read(calibrationFactorProvider.notifier)
                    .setFactor(newFactor);
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.flag_outlined),
            tooltip: 'Set daily target',
            onPressed: () async {
              final newTarget = await showEditTargetDialog(context, target);
              if (newTarget != null) {
                ref.read(dailyTargetProvider.notifier).setTarget(newTarget);
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.route),
            tooltip: 'My Routes',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (context) => const RoutesPage()),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: _body(
          stepsAsync: stepsAsync,
          target: target,
          walkingStatus: walkingStatus,
          heightCm: heightCm,
          weightKg: weightKg,
          unitSystem: unitSystem,
          sensorAvailable: sensorAvailable,
        ),
      ),
    );
  }
}

class _StepContent extends ConsumerWidget {
  final int steps;
  final int target;
  final String? walkingStatus;
  final double? heightCm;
  final double? weightKg;
  final UnitSystem unitSystem;

  const _StepContent({
    required this.steps,
    required this.target,
    this.walkingStatus,
    this.heightCm,
    this.weightKg,
    required this.unitSystem,
  });

  DistanceResult get _distance => StepMetrics.distance(
        steps,
        heightCm: heightCm,
        unit: unitSystem,
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final past7Days = ref.watch(past7DaysProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 8),
          StepProgressRing(currentSteps: steps, dailyTarget: target),
          const SizedBox(height: 24),
          Row(
            children: [
              MetricCard(
                icon: Icons.route,
                label: 'Distance',
                value: _distance.value.toStringAsFixed(2),
                unit: _distance.unit,
              ),
              const SizedBox(width: 12),
              MetricCard(
                icon: Icons.local_fire_department,
                label: 'Calories',
                value: StepMetrics.calories(steps, weightKg: weightKg)
                    .toStringAsFixed(0),
                unit: 'kcal',
              ),
              const SizedBox(width: 12),
              MetricCard(
                icon: Icons.timer_outlined,
                label: 'Active time',
                value: StepMetrics.activeMinutes(steps).toStringAsFixed(0),
                unit: 'min',
              ),
            ],
          ),
          const SizedBox(height: 32),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Past 7 days', style: theme.textTheme.titleMedium),
              Text(
                'Target: $target steps',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 12),
          past7Days.when(
            data: (records) => WeeklyBarChart(
              last7Days: records,
              dailyTarget: target,
              onDaySelected: (date) =>
                  showHourlyBreakdownDialog(context, date),
            ),
            loading: () => const SizedBox(
              height: 240,
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => SizedBox(
              height: 240,
              child: Center(child: Text('Error loading chart: $e')),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown only once the background service has confirmed missing hardware.
class _SensorUnavailable extends StatelessWidget {
  const _SensorUnavailable();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.sensors_off, size: 48),
            SizedBox(height: 16),
            Text(
              "This device doesn't have a step-count sensor, so live "
              "tracking isn't available.",
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when the permission is permanently denied.
class _PermissionBlocked extends StatelessWidget {
  final VoidCallback onOpenSettings;

  const _PermissionBlocked({required this.onOpenSettings});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.directions_walk, size: 48),
            const SizedBox(height: 16),
            const Text(
              'Activity permission is turned off, and Android won\'t ask '
              'again. Turn on Physical activity in Settings to start '
              'counting steps.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onOpenSettings,
              child: const Text('Open settings'),
            ),
          ],
        ),
      ),
    );
  }
}

class _BackgroundServiceFailedBanner extends StatelessWidget {
  final VoidCallback onRetry;

  const _BackgroundServiceFailedBanner({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MaterialBanner(
      backgroundColor: theme.colorScheme.errorContainer,
      leading: Icon(Icons.warning_amber, color: theme.colorScheme.onErrorContainer),
      content: Text(
        "Step tracking couldn't start — your steps may not be counted "
        "until this is retried.",
        style: TextStyle(color: theme.colorScheme.onErrorContainer),
      ),
      actions: [
        TextButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    );
  }
}

class _PermissionDenied extends StatelessWidget {
  final VoidCallback onRetry;

  const _PermissionDenied({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.directions_walk, size: 48),
            const SizedBox(height: 16),
            const Text(
              'Step Counter needs activity/motion permission to count '
              'your steps.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onRetry,
              child: const Text('Grant permission'),
            ),
          ],
        ),
      ),
    );
  }
}
