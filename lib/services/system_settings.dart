import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The system screens and states the app needs but Flutter can't reach on
/// its own. Backed by the method channel in `MainActivity.kt`.
class SystemSettings {
  const SystemSettings();

  static const MethodChannel _channel =
      MethodChannel('com.nttech.roamfree/system');

  /// Null means the platform can't say (iOS, or no channel) — callers treat
  /// that as "say nothing", never as "not exempt".
  Future<bool?> isBatteryExempt() =>
      _invoke<bool>('isIgnoringBatteryOptimizations');

  /// Opens the system list where the battery exemption is granted.
  Future<bool> openBatteryOptimizationSettings() async =>
      await _invoke<bool>('openBatteryOptimizationSettings') ?? false;

  /// Opens [channelId]'s own settings, where it can be silenced without
  /// being turned off.
  Future<bool> openNotificationChannelSettings(String channelId) async =>
      await _invoke<bool>(
        'openNotificationChannelSettings',
        {'channelId': channelId},
      ) ??
      false;

  /// Null on any failure — a missing channel off Android is routine, not
  /// worth surfacing.
  Future<T?> _invoke<T>(String method, [Map<String, Object?>? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      debugPrint('[SystemSettings] $method failed: $error');
      return null;
    }
  }
}
