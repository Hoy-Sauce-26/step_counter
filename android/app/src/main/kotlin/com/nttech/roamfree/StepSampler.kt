package com.nttech.roamfree

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.Calendar

/**
 * Takes a counter reading every so often, whether or not anything is running.
 *
 * This is the safety net under the whole design: the hardware counter is
 * cumulative, so a reading now and a reading later is all it takes to know
 * what happened in between. Sampling bounds how much a gap can cost — without
 * it, a reboot while the foreground service is off loses everything since the
 * app was last opened, because the counter zeroes and there is no reading on
 * the other side of it.
 *
 * Deliberately native. Spinning a Flutter engine for a two-column insert
 * would cost more than the sample it is taking.
 */
object StepSampler {
    private const val TAG = "StepSampler"
    private const val REQUEST_CODE = 4201
    const val ACTION_SAMPLE = "com.nttech.roamfree.SAMPLE_STEPS"

    private const val INTERVAL_MS = 15 * 60 * 1000L

    /**
     * Inexact on purpose. An exact alarm needs SCHEDULE_EXACT_ALARM, which is
     * a restricted Play Console permission, and `setAndAllowWhileIdle` still
     * fires through Doze. A sample landing a few minutes late costs a few
     * minutes of attribution accuracy; nothing is ever lost by it.
     */
    fun schedule(context: Context) {
        val alarms = context.getSystemService(AlarmManager::class.java) ?: return
        alarms.setAndAllowWhileIdle(
            AlarmManager.RTC_WAKEUP,
            nextFireTime(),
            pendingIntent(context),
        )
    }

    fun cancel(context: Context) {
        context.getSystemService(AlarmManager::class.java)
            ?.cancel(pendingIntent(context))
    }

    /**
     * The sooner of one interval away and the next midnight.
     *
     * The midnight anchor is what makes daily totals exact: the fold credits
     * an interval's steps to the day it began in, so a reading close to the
     * boundary keeps one day's walking from landing on the next.
     */
    private fun nextFireTime(now: Long = System.currentTimeMillis()): Long {
        val midnight = Calendar.getInstance().apply {
            timeInMillis = now
            add(Calendar.DAY_OF_YEAR, 1)
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis

        return minOf(now + INTERVAL_MS, midnight)
    }

    private fun pendingIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context,
        REQUEST_CODE,
        Intent(context, StepSampleReceiver::class.java).setAction(ACTION_SAMPLE),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    /**
     * Reads the counter once and hands the value back.
     *
     * `TYPE_STEP_COUNTER` is an on-change sensor, so the platform reports its
     * current value the moment a listener registers — no walking, no waiting.
     */
    fun readOnce(context: Context, timeoutMs: Long, onResult: (Int?) -> Unit) {
        val sensors = context.getSystemService(SensorManager::class.java)
        val sensor = sensors?.getDefaultSensor(Sensor.TYPE_STEP_COUNTER)
        if (sensor == null) {
            onResult(null)
            return
        }

        val handler = Handler(Looper.getMainLooper())
        var settled = false
        var timeout: Runnable? = null

        val listener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                if (settled) return
                settled = true
                sensors.unregisterListener(this)
                timeout?.let { handler.removeCallbacks(it) }
                onResult(event.values[0].toInt())
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
        }

        timeout = Runnable {
            if (settled) return@Runnable
            settled = true
            sensors.unregisterListener(listener)
            onResult(null)
        }
        handler.postDelayed(timeout, timeoutMs)

        sensors.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_FASTEST, handler)
    }
}

/** Fires on the sampler's alarm: one reading, one row, then re-arm. */
class StepSampleReceiver : BroadcastReceiver() {
    private companion object {
        const val TAG = "StepSampleReceiver"
        // Well inside a receiver's budget; the sensor answers in milliseconds.
        const val READ_TIMEOUT_MS = 3_000L
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != StepSampler.ACTION_SAMPLE) return

        val app = context.applicationContext
        // The reading is asynchronous, so the receiver has to be kept alive
        // past the end of this method.
        val pending = goAsync()

        // Re-armed first: a failure below must not end the sampling.
        StepSampler.schedule(app)

        StepSampler.readOnce(app, READ_TIMEOUT_MS) { rawSteps ->
            try {
                if (rawSteps != null) {
                    JournalWriter.append(app, System.currentTimeMillis(), rawSteps)
                } else {
                    Log.w(TAG, "no step counter answered in time")
                }
            } finally {
                pending.finish()
            }
        }
    }
}
