import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:step_counter/screens/settings_page.dart';
import 'package:step_counter/services/providers.dart';
import 'package:step_counter/services/system_settings.dart';

/// Stands in for the platform channel. [exempt] is the answer
/// `isBatteryExempt` gives, including null for "this platform can't say".
class _FakeSystemSettings implements SystemSettings {
  _FakeSystemSettings(this.exempt);

  final bool? exempt;
  int notificationSettingsOpened = 0;
  int batterySettingsOpened = 0;

  @override
  Future<bool?> isBatteryExempt() async => exempt;

  @override
  Future<bool> openBatteryOptimizationSettings() async {
    batterySettingsOpened++;
    return true;
  }

  @override
  Future<bool> openNotificationChannelSettings(String channelId) async {
    notificationSettingsOpened++;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<_FakeSystemSettings> pumpSettings(
    WidgetTester tester, {
    required bool? exempt,
  }) async {
    SharedPreferences.setMockInitialValues({});
    // Tall enough that the whole page fits: the default 800x600 test
    // viewport leaves the notification row off-screen and untappable.
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final system = _FakeSystemSettings(exempt);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [systemSettingsProvider.overrideWithValue(system)],
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
    return system;
  }

  testWidgets('every section the app always owns is present', (tester) async {
    await pumpSettings(tester, exempt: true);

    expect(find.text('Daily target'), findsOneWidget);
    expect(find.text('Height, weight & units'), findsOneWidget);
    expect(find.text('Calibration'), findsOneWidget);
    expect(find.text('Show ongoing notification'), findsOneWidget);
  });

  testWidgets('an unanswerable platform hides the battery section entirely',
      (tester) async {
    await pumpSettings(tester, exempt: null);

    expect(find.text('Battery optimization is on'), findsNothing);
    expect(find.text('Running unrestricted'), findsNothing,
        reason: 'an unknown is not a problem worth showing somebody');
  });

  testWidgets('an optimized app is offered the exemption', (tester) async {
    final system = await pumpSettings(tester, exempt: false);

    expect(find.text('Battery optimization is on'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Allow'));
    await tester.pumpAndSettle();

    expect(system.batterySettingsOpened, 1);
  });

  testWidgets('an exempt app is told so and given nothing to press',
      (tester) async {
    await pumpSettings(tester, exempt: true);

    expect(find.text('Running unrestricted'), findsOneWidget);
    expect(find.text('Battery optimization is on'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Allow'), findsNothing);
  });

  testWidgets('the notification can be switched off outright', (tester) async {
    await pumpSettings(tester, exempt: true);

    // Only truthful since the journal: turning the service off no longer
    // turns counting off with it.
    expect(find.byType(SwitchListTile), findsOneWidget);
    expect(find.text('Show ongoing notification'), findsOneWidget);
  });

  testWidgets('with the notification on, it can still be quietened',
      (tester) async {
    final system = await pumpSettings(tester, exempt: true);

    await tester.tap(find.text('Make it quieter'));
    await tester.pumpAndSettle();

    expect(system.notificationSettingsOpened, 1);
  });

  testWidgets('the subtitle promises the count survives being switched off',
      (tester) async {
    await pumpSettings(tester, exempt: true);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(find.textContaining('still counted'), findsOneWidget,
        reason: 'the reason the switch is offerable at all');
    expect(find.text('Make it quieter'), findsNothing,
        reason: 'nothing to quieten once there is no notification');
  });

  testWidgets('unset personal details read as unset rather than as zeroes',
      (tester) async {
    await pumpSettings(tester, exempt: true);

    expect(find.text('Not set · Metric'), findsOneWidget);
  });
}
