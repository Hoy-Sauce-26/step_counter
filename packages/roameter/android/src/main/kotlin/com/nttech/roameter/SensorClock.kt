package com.nttech.roameter

import android.os.SystemClock
import kotlin.math.abs

/**
 * Turns a `SensorEvent.timestamp` into wall-clock epoch milliseconds.
 *
 * The documented unit is nanoseconds since boot, so the conversion needs both
 * clocks. Some OEM stacks report epoch nanoseconds instead, which is why the
 * result is sanity-checked rather than trusted.
 */
object SensorClock {
    // Generous, because an on-change sensor's first event carries the time the
    // value last changed — possibly hours ago if nobody has walked. The bug
    // this guards against is off by decades, not hours.
    private const val PLAUSIBLE_AGE_MS = 7L * 24 * 60 * 60 * 1000

    fun toEpochMillis(
        sensorTimestampNanos: Long,
        now: Long = System.currentTimeMillis(),
        elapsedRealtime: Long = SystemClock.elapsedRealtime(),
    ): Long {
        val asMillis = sensorTimestampNanos / 1_000_000L
        val sinceBoot = now - elapsedRealtime + asMillis

        return when {
            abs(sinceBoot - now) <= PLAUSIBLE_AGE_MS -> sinceBoot
            // Already epoch millis — the OEM case.
            abs(asMillis - now) <= PLAUSIBLE_AGE_MS -> asMillis
            // Neither reading is believable; arrival time is the honest answer.
            else -> now
        }
    }
}
