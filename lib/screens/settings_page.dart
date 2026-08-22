import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/metrics.dart';
import '../services/notification_service.dart';
import '../services/providers.dart';
import '../widgets/calibration_dialog.dart';
import '../widgets/edit_target_dialog.dart';
import '../widgets/personalize_dialog.dart';

/// Everything that used to be an icon in the app bar, plus the system
/// settings the app can only point at rather than change.
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage>
    with WidgetsBindingObserver {
  /// Null while unknown or unanswerable — the section stays hidden rather
  /// than guessing.
  bool? _batteryExempt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshBatteryStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The exemption is granted in the system settings app.
    if (state == AppLifecycleState.resumed) _refreshBatteryStatus();
  }

  Future<void> _refreshBatteryStatus() async {
    final exempt = await ref.read(systemSettingsProvider).isBatteryExempt();
    if (!mounted || exempt == _batteryExempt) return;
    setState(() => _batteryExempt = exempt);
  }

  Future<void> _openBatterySettings() async {
    final opened =
        await ref.read(systemSettingsProvider).openBatteryOptimizationSettings();
    if (opened || !mounted) return;
    _reportNoSystemScreen(
      'battery or power settings under Roamfree in Settings',
    );
  }

  Future<void> _openNotificationSettings() async {
    final opened = await ref
        .read(systemSettingsProvider)
        .openNotificationChannelSettings(NotificationService.channelId);
    if (opened || !mounted) return;
    _reportNoSystemScreen('Roamfree under Settings, then Notifications');
  }

  void _reportNoSystemScreen(String where) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("This phone doesn't have that screen — look for $where."),
      ),
    );
  }

  Future<void> _editTarget(int target) async {
    final updated = await showEditTargetDialog(context, target);
    if (updated == null) return;
    ref.read(dailyTargetProvider.notifier).update(updated);
  }

  Future<void> _editPersonalDetails({
    required double? heightCm,
    required double? weightKg,
    required UnitSystem unitSystem,
  }) async {
    final result = await showPersonalizeDialog(
      context,
      currentHeightCm: heightCm,
      currentWeightKg: weightKg,
      currentUnitSystem: unitSystem,
    );
    if (result == null) return;
    ref.read(heightCmProvider.notifier).update(result.heightCm);
    ref.read(weightKgProvider.notifier).update(result.weightKg);
    ref.read(unitSystemProvider.notifier).update(result.unitSystem);
  }

  Future<void> _editCalibration(double factor, double stepsPerMinute) async {
    final result = await showCalibrationDialog(
      context,
      factor,
      stepsPerMinute,
      ref.read(pedometerServiceProvider),
    );
    if (result == null) return;
    ref.read(calibrationFactorProvider.notifier).update(result.correctionFactor);
    ref.read(stepsPerMinuteProvider.notifier).update(result.stepsPerMinute);
  }

  @override
  Widget build(BuildContext context) {
    final target = ref.watch(dailyTargetProvider);
    final heightCm = ref.watch(heightCmProvider);
    final weightKg = ref.watch(weightKgProvider);
    final unitSystem = ref.watch(unitSystemProvider);
    final factor = ref.watch(calibrationFactorProvider);
    final stepsPerMinute = ref.watch(stepsPerMinuteProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _SectionHeader('Goal'),
          ListTile(
            leading: const Icon(Icons.flag_outlined),
            title: const Text('Daily target'),
            subtitle: Text('$target steps'),
            onTap: () => _editTarget(target),
          ),

          const _SectionHeader('About you'),
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Height, weight & units'),
            subtitle: Text(_personalSummary(
              heightCm: heightCm,
              weightKg: weightKg,
              unitSystem: unitSystem,
            )),
            onTap: () => _editPersonalDetails(
              heightCm: heightCm,
              weightKg: weightKg,
              unitSystem: unitSystem,
            ),
          ),

          const _SectionHeader('Accuracy'),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('Calibration'),
            subtitle: Text(
              'Counting at ${(factor * 100).round()}% · '
              '${stepsPerMinute.round()} steps/min',
            ),
            onTap: () => _editCalibration(factor, stepsPerMinute),
          ),

          // Hidden entirely when the platform can't answer.
          if (_batteryExempt != null) ...[
            const _SectionHeader('Battery'),
            if (_batteryExempt == false)
              ListTile(
                leading: Icon(
                  Icons.battery_alert_outlined,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: const Text('Battery optimization is on'),
                subtitle: const Text(
                  'Android can stop Roamfree in the background to save power, '
                  'which makes it miss steps.',
                ),
                isThreeLine: true,
                trailing: FilledButton(
                  onPressed: _openBatterySettings,
                  child: const Text('Allow'),
                ),
              )
            else
              const ListTile(
                leading: Icon(Icons.battery_full_outlined),
                title: Text('Running unrestricted'),
                subtitle: Text(
                  "Android won't stop Roamfree in the background, so it keeps "
                  'counting.',
                ),
              ),
          ],

          const _SectionHeader('Notification'),
          // No switch: the notification keeps the service alive, so a toggle
          // would either lie or quietly stop tracking. Copy leads with "no
          // off switch" before explaining why, and keeps "exists" separate
          // from "how loud" — an earlier draft blurred them into what read
          // as a contradiction.
          ListTile(
            leading: const Icon(Icons.notifications_none),
            title: const Text('Ongoing notification'),
            subtitle: const Text(
              "Roamfree can't switch this off — it's what lets the app keep "
              "counting while it's closed. You can still make it silent and "
              'shrink it to a single line.',
            ),
            isThreeLine: true,
            // Whole row, not a button — cramped otherwise. Icon is Android's
            // usual "this leaves the app" signal.
            trailing: const Icon(Icons.open_in_new, size: 20),
            onTap: _openNotificationSettings,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  String _personalSummary({
    required double? heightCm,
    required double? weightKg,
    required UnitSystem unitSystem,
  }) {
    final units = unitSystem == UnitSystem.imperial ? 'Imperial' : 'Metric';
    final parts = <String>[
      if (heightCm != null) _height(heightCm, unitSystem),
      if (weightKg != null) _weight(weightKg, unitSystem),
      units,
    ];
    // "Not set" is a real state — estimates fall back to flat rates.
    if (heightCm == null && weightKg == null) {
      return 'Not set · $units';
    }
    return parts.join(' · ');
  }

  String _height(double cm, UnitSystem unitSystem) {
    if (unitSystem == UnitSystem.metric) return '${cm.round()} cm';
    final totalInches = cm / 2.54;
    return "${(totalInches ~/ 12)}'${(totalInches % 12).round()}\"";
  }

  String _weight(double kg, UnitSystem unitSystem) {
    if (unitSystem == UnitSystem.metric) return '${kg.round()} kg';
    return '${(kg * 2.20462).round()} lb';
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;

  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}
