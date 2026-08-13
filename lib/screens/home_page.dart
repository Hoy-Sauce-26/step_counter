import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/metrics.dart';
import '../services/providers.dart';
import '../widgets/calibration_dialog.dart';
import '../widgets/charts/weekly_bar_chart.dart';
import '../widgets/edit_target_dialog.dart';
import '../widgets/hourly_breakdown_dialog.dart';
import '../widgets/metric_card.dart';
import '../widgets/personalize_dialog.dart';
import '../widgets/step_progress_ring.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage>
    with WidgetsBindingObserver {
  bool _permissionChecked = false;
  bool _permissionGranted = false;

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
      // Fixes a real bug: without this, if the calendar date rolled over
      // while the app was closed and no step has happened yet today, the
      // UI keeps showing yesterday's stale total until a fresh step event
      // forces a recheck — confusing on exactly the mornings someone
      // opens the app first thing. Re-seeding on every resume means the
      // displayed value is always correct the instant the screen appears.
      ref.read(pedometerServiceProvider).refreshForCurrentDate();

      // Defensive: if the background service somehow isn't running
      // (killed by an aggressive OEM battery manager, first run after
      // this update, etc.), restart it rather than silently going
      // without tracking until the next full app restart.
      _ensureBackgroundServiceRunning();
    }
  }

  Future<void> _ensureBackgroundServiceRunning() async {
    if (!_permissionGranted) return;
    final bgService = FlutterBackgroundService();
    final isRunning = await bgService.isRunning();
    if (!isRunning) {
      await bgService.startService();
    }
  }

  Future<void> _ensurePermission() async {
    final service = ref.read(pedometerServiceProvider);
    var granted = await service.hasPermission();
    if (!granted) {
      granted = await service.requestPermission();
    }
    if (mounted) {
      setState(() {
        _permissionChecked = true;
        _permissionGranted = granted;
      });
    }
    if (granted) {
      // The providers' very first call to service.start() happens as soon
      // as this screen builds — on a fresh install, that's typically
      // before this permission flow has resolved, so start() will have
      // bailed out without registering the sensor listeners. Now that
      // permission is confirmed, retry; start() is a no-op if it already
      // succeeded.
      await service.start();
      await _ensureBackgroundServiceRunning();
    }
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
        ],
      ),
      body: SafeArea(
        child: !_permissionChecked
            ? const Center(child: CircularProgressIndicator())
            : !_permissionGranted
                ? _PermissionDenied(onRetry: _ensurePermission)
                : stepsAsync.when(
                    data: (steps) => _StepContent(
                      steps: steps,
                      target: target,
                      walkingStatus: walkingStatus,
                      heightCm: heightCm,
                      weightKg: weightKg,
                      unitSystem: unitSystem,
                    ),
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (err, st) => Center(
                      child: Text('Sensor error: $err'),
                    ),
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
    if (steps < 0) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            "This device doesn't report a step-count sensor, "
            "so live tracking isn't available.",
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

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
