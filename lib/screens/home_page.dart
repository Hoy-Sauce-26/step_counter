import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/background_service.dart';
import '../services/tracking_service.dart';
import '../services/formatting.dart';
import '../services/metrics.dart';
import '../services/pedometer_service.dart';
import '../services/providers.dart';
import '../widgets/add_steps_dialog.dart';
import '../widgets/charts/weekly_bar_chart.dart';
import '../widgets/hourly_breakdown_dialog.dart';
import '../widgets/metric_card.dart';
import '../widgets/step_progress_ring.dart';
import 'routes_page.dart';
import 'settings_page.dart';

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

  bool _ensuringBackgroundService = false;
  bool _backgroundServiceFailed = false;

  /// How long tracking was silent, or null once dismissed.
  Duration? _recoveredStallGap;

  /// Whether the battery-optimizer prompt should show.
  bool _showBatteryPrompt = false;

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

      _refreshBatteryPrompt();
    }
  }

  Future<void> _ensureBackgroundServiceRunning() async {
    if (!_permissionGranted || _ensuringBackgroundService) return;
    _ensuringBackgroundService = true;
    try {
      final bgService = TrackingService();
      if (!await bgService.isRunning()) {
        await bgService.start(onServiceStart);
      } else {
        // "Running" per Android — see [stalledFor] for why that's weaker
        // than it sounds.
        final stalled = await _stalledDuration();
        if (stalled != null) {
          if (await _restartBackgroundService(bgService)) {
            if (mounted) setState(() => _recoveredStallGap = stalled);
          } else {
            // Won't restart — show the failure banner, not a false recovery.
            if (mounted) setState(() => _backgroundServiceFailed = true);
            return;
          }
        }
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

  /// How long the background service has been silent, if enough to count.
  Future<Duration?> _stalledDuration() async {
    final prefs = ref.read(preferencesServiceProvider);
    // The heartbeat is written by the other isolate — reload or this answers
    // from a stale snapshot taken at app start.
    await prefs.reload();
    return stalledFor(
      lastHeartbeat: await prefs.getServiceHeartbeat(),
      now: DateTime.now(),
    );
  }

  /// Stops the service before starting it again. False if it wouldn't stop.
  Future<bool> _restartBackgroundService(TrackingService bgService) async {
    bgService.invoke('stopService');
    // Polled, with a ceiling so a service that refuses to stop can't hang
    // the resume path.
    var stopped = false;
    for (var i = 0; i < 20; i++) {
      if (!await bgService.isRunning()) {
        stopped = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    // Starting a service that never stopped is a no-op.
    if (!stopped) return false;

    await bgService.start(onServiceStart);
    return bgService.isRunning();
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
    await _refreshBatteryPrompt();
  }

  /// Null means the platform couldn't say — stays quiet rather than nagging
  /// on a guess.
  Future<void> _refreshBatteryPrompt() async {
    final exempt = await ref.read(systemSettingsProvider).isBatteryExempt();
    if (exempt != false) {
      if (mounted && _showBatteryPrompt) {
        setState(() => _showBatteryPrompt = false);
      }
      return;
    }
    final dismissed =
        await ref.read(preferencesServiceProvider).getBatteryPromptDismissed();
    if (!mounted) return;
    setState(() => _showBatteryPrompt = !dismissed);
  }

  Future<void> _openBatterySettings() async {
    final opened = await ref.read(systemSettingsProvider).openBatteryOptimizationSettings();
    if (opened || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          "This phone doesn't have the standard battery screen — look for "
          'battery or power settings under Roamfree in Settings.',
        ),
      ),
    );
  }

  Future<void> _dismissBatteryPrompt() async {
    setState(() => _showBatteryPrompt = false);
    await ref
        .read(preferencesServiceProvider)
        .setBatteryPromptDismissed(true);
  }

  Future<void> _openPermissionSettings() async {
    await ref.read(pedometerServiceProvider).openPermissionSettings();
  }

  Widget _body({
    required AsyncValue<int> stepsAsync,
    required int target,
    required double? heightCm,
    required double? weightKg,
    required double stepsPerMinute,
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
        heightCm: heightCm,
        weightKg: weightKg,
        stepsPerMinute: stepsPerMinute,
        unitSystem: unitSystem,
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, st) => Center(child: Text('Sensor error: $err')),
    );
    // At most one banner, in priority order — stacking them pushes the ring
    // off screen.
    final gap = _recoveredStallGap;
    final Widget? banner;
    if (_backgroundServiceFailed) {
      banner = _BackgroundServiceFailedBanner(
        onRetry: _ensureBackgroundServiceRunning,
      );
    } else if (gap != null) {
      banner = _TrackingRecoveredBanner(
        stalledFor: gap,
        onDismiss: () => setState(() => _recoveredStallGap = null),
      );
    } else if (_showBatteryPrompt) {
      banner = _BatteryOptimizationBanner(
        onOpenSettings: _openBatterySettings,
        onDismiss: _dismissBatteryPrompt,
      );
    } else {
      banner = null;
    }
    if (banner == null) return content;

    return Column(
      children: [banner, Expanded(child: content)],
    );
  }

  @override
  Widget build(BuildContext context) {
    final target = ref.watch(dailyTargetProvider);
    final stepsPerMinute = ref.watch(stepsPerMinuteProvider);
    final heightCm = ref.watch(heightCmProvider);
    final weightKg = ref.watch(weightKgProvider);
    final unitSystem = ref.watch(unitSystemProvider);
    final stepsAsync = ref.watch(todayStepsProvider);

    final sensorAvailable = ref.watch(stepSensorAvailableProvider).value;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Roamfree'),
        actions: [
          IconButton(
            icon: const Icon(Icons.route),
            tooltip: 'My Routes',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (context) => const RoutesPage()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (context) => const SettingsPage()),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: _body(
          stepsAsync: stepsAsync,
          target: target,
          heightCm: heightCm,
          weightKg: weightKg,
          stepsPerMinute: stepsPerMinute,
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
  final double? heightCm;
  final double? weightKg;
  final double stepsPerMinute;
  final UnitSystem unitSystem;

  const _StepContent({
    required this.steps,
    required this.target,
    this.heightCm,
    this.weightKg,
    required this.stepsPerMinute,
    required this.unitSystem,
  });

  DistanceResult get _distance => StepMetrics.distance(
        steps,
        heightCm: heightCm,
        unit: unitSystem,
      );

  /// Credits steps the sensor never saw. The service broadcasts the new total
  /// back over `stepUpdate`, so nothing here has to refresh the count.
  Future<void> _addSteps(BuildContext context, WidgetRef ref) async {
    final amount = await showAddStepsDialog(context);
    if (amount == null) return;

    await ref.read(pedometerServiceProvider).addManualSteps(amount);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Added $amount steps to today')),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final past7Days = ref.watch(past7DaysProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 8),
          StepProgressRing(
            currentSteps: steps,
            dailyTarget: target,
            onTap: () => _addSteps(context, ref),
          ),
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
                value: StepMetrics.calories(
                  steps,
                  weightKg: weightKg,
                  heightCm: heightCm,
                  stepsPerMinute: stepsPerMinute,
                ).toStringAsFixed(0),
                unit: 'kcal',
              ),
              const SizedBox(width: 12),
              MetricCard(
                icon: Icons.timer_outlined,
                label: 'Active time',
                value: StepMetrics.activeMinutes(
                  steps,
                  stepsPerMinute: stepsPerMinute,
                ).toStringAsFixed(0),
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
              onDaySelected: (date) => showHourlyBreakdownDialog(context, date),
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

/// Offers the battery-optimizer exemption, once — dismissing is permanent.
class _BatteryOptimizationBanner extends StatelessWidget {
  final VoidCallback onOpenSettings;
  final VoidCallback onDismiss;

  const _BatteryOptimizationBanner({
    required this.onOpenSettings,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MaterialBanner(
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
      leading: Icon(
        Icons.battery_saver_outlined,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      content: Text(
        'Android can stop Roamfree in the background to save power, which '
        'makes it miss steps. Letting it run unrestricted keeps your count '
        'complete.',
        style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
      ),
      actions: [
        TextButton(onPressed: onDismiss, child: const Text('Not now')),
        TextButton(onPressed: onOpenSettings, child: const Text('Open settings')),
      ],
    );
  }
}

/// Shown after a stalled service is caught and restarted — not an error,
/// since today's count has already caught up. What's actually lost is any
/// full day the service missed, which this says plainly.
class _TrackingRecoveredBanner extends StatelessWidget {
  final Duration stalledFor;
  final VoidCallback onDismiss;

  const _TrackingRecoveredBanner({
    required this.stalledFor,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MaterialBanner(
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
      leading: Icon(Icons.history, color: theme.colorScheme.onSurfaceVariant),
      content: Text(
        'Step tracking stopped for ${formatApproximateDuration(stalledFor)} '
        "and has restarted. Today's count has caught up, but a full day it "
        'missed will read zero.',
        style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
      ),
      actions: [
        TextButton(onPressed: onDismiss, child: const Text('Dismiss')),
      ],
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
      leading:
          Icon(Icons.warning_amber, color: theme.colorScheme.onErrorContainer),
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
              'Roamfree needs activity permission to count your steps.',
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
