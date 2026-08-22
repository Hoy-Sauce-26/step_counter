package com.nttech.roamfree

import android.content.Context

/**
 * The raw handle of the Dart entrypoint the service runs.
 *
 * Persisted because the service starts on boot too, long before any Dart has
 * run to tell us what to execute. Its own preferences file, so it can't
 * collide with the `flutter.`-prefixed keys the app's own storage uses.
 */
object TrackingCallback {
    private const val FILE = "roamfree_tracking_service"
    private const val KEY_HANDLE = "entrypointHandle"

    fun store(context: Context, handle: Long) {
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
            .edit()
            .putLong(KEY_HANDLE, handle)
            .apply()
    }

    /** Zero when nothing has been stored yet — the app has never launched. */
    fun read(context: Context): Long =
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
            .getLong(KEY_HANDLE, 0L)
}
