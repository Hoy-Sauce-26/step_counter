package com.nttech.roamfree

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Brings tracking back after a reboot or an app update.
 *
 * Only starts if an entrypoint has been registered — i.e. the app has been
 * opened at least once. Android holds a freshly installed app in a stopped
 * state that blocks this broadcast entirely until then, so there is nothing
 * to do on a first install regardless.
 *
 * Also respects the user's notification setting, which is why that setting
 * has to be readable from Kotlin: this fires long before any Dart does.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val relevant = intent.action == Intent.ACTION_BOOT_COMPLETED ||
            intent.action == Intent.ACTION_MY_PACKAGE_REPLACED ||
            intent.action == "android.intent.action.QUICKBOOT_POWERON"
        if (!relevant) return
        if (TrackingCallback.read(context) == 0L) return

        // Sampling comes back either way: it is what keeps a day the service
        // never ran from reading zero, and a reboot is exactly when the
        // counter zeroes and a reading on the far side matters most.
        StepSampler.schedule(context)

        // The service itself is the user's choice. Someone who turned the
        // notification off does not want it back on every reboot and update.
        if (!TrackingPreference.isForegroundTrackingEnabled(context)) return

        StepTrackingService.start(context)
    }
}
