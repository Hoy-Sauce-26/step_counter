package com.nttech.roamfree

import android.content.Context
import android.content.Intent
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private companion object {
        const val CHANNEL = "com.nttech.roamfree/system"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isIgnoringBatteryOptimizations" ->
                        result.success(isIgnoringBatteryOptimizations())

                    "openBatteryOptimizationSettings" ->
                        result.success(openBatteryOptimizationSettings())

                    "openNotificationChannelSettings" ->
                        result.success(
                            openNotificationChannelSettings(call.argument("channelId"))
                        )

                    else -> result.notImplemented()
                }
            }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        return power.isIgnoringBatteryOptimizations(packageName)
    }

    // Not REQUEST_IGNORE_BATTERY_OPTIMIZATIONS: that's a restricted Play
    // Console permission. This reaches the same setting with no policy risk.
    private fun openBatteryOptimizationSettings(): Boolean =
        launch(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))

    // Importance can drop to silent here without turning the channel off.
    private fun openNotificationChannelSettings(channelId: String?): Boolean {
        if (channelId == null) return false
        return launch(
            Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                .putExtra(Settings.EXTRA_CHANNEL_ID, channelId)
        )
    }

    // False when nothing resolves the intent (some OEM builds move the screen).
    private fun launch(intent: Intent): Boolean = try {
        startActivity(intent)
        true
    } catch (error: Exception) {
        false
    }
}
