import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/metrics.dart';
import '../services/providers.dart';
import '../widgets/calibration_dialog.dart';
import '../widgets/edit_target_dialog.dart';
import '../widgets/metric_card.dart';
import '../widgets/step_progress_ring.dart';
import 'analytics_page.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  bool _permissionChecked = false;
  bool _permissionGranted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensurePermission());
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
    }
  }

  @override
  Widget build(BuildContext context) {
    final target = ref.watch(dailyTargetProvider);
    final stepsAsync = ref.watch(todayStepsProvider);
    final walkingStatus = ref.watch(walkingStatusProvider).value;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Step Counter'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bar_chart),
            tooltip: 'Analytics',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AnalyticsPage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'Calibrate step count',
            onPressed: () async {
              final currentFactor = ref.read(calibrationFactorProvider);
              final pedometerService = ref.read(pedometerServiceProvider);
              final newFactor = await showCalibrationDialog(
                context,
                currentFactor,
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

class _StepContent extends StatelessWidget {
  final int steps;
  final int target;
  final String? walkingStatus;

  const _StepContent({
    required this.steps,
    required this.target,
    this.walkingStatus,
  });

  @override
  Widget build(BuildContext context) {
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

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 8),
          StepProgressRing(currentSteps: steps, dailyTarget: target),
          if (steps == 0) ...[
            const SizedBox(height: 16),
            if (walkingStatus == 'walking')
              Chip(
                avatar: Icon(Icons.directions_walk,
                    size: 18, color: theme.colorScheme.primary),
                label: const Text('Motion detected'),
              ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Waiting for your first step to be detected — take a few '
                'steps with your phone on you.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
          const SizedBox(height: 24),
          Row(
            children: [
              MetricCard(
                icon: Icons.route,
                label: 'Distance',
                value: StepMetrics.distanceKm(steps).toStringAsFixed(2),
                unit: 'km',
              ),
              const SizedBox(width: 12),
              MetricCard(
                icon: Icons.local_fire_department,
                label: 'Calories',
                value: StepMetrics.calories(steps).toStringAsFixed(0),
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
