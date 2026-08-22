package com.nttech.roamfree

import android.content.Context

/**
 * Whether the user wants the foreground service running.
 *
 * Read from the same file Flutter's shared_preferences writes, because the
 * decision has to be available on boot — long before any Dart runs to be
 * asked. Defaults to on: that is the app's default too, and a fresh install
 * has no answer stored.
 */
object TrackingPreference {
    private const val FILE = "FlutterSharedPreferences"
    private const val KEY = "flutter.foregroundTrackingEnabled"

    fun isForegroundTrackingEnabled(context: Context): Boolean =
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
            .getBoolean(KEY, true)
}
