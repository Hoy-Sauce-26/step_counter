import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/metrics.dart';
import '../services/providers.dart';
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
  }

  @override
  Widget build(BuildContext context) {
    final target = ref.watch(dailyTargetProvider);
    final stepsAsync = ref.watch(todayStepsProvider);

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
                    data: (steps) => _StepContent(steps: steps, target: target),
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

  const _StepContent({required this.steps, required this.target});

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

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 8),
          StepProgressRing(currentSteps: steps, dailyTarget: target),
          const SizedBox(height: 32),
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
