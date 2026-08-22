package com.nttech.roameter

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class RoameterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private companion object {
        const val METHODS = "roameter/methods"
        const val STEP_COUNTS = "roameter/step_counts"

        // Long enough for a stack that doesn't report on registration, short
        // enough that a sampler isn't left hanging.
        const val ONE_SHOT_TIMEOUT_MS = 2_000L
    }

    private lateinit var methods: MethodChannel
    private lateinit var stepCounts: EventChannel
    private lateinit var sensors: SensorManager
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        sensors = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager

        methods = MethodChannel(binding.binaryMessenger, METHODS)
        methods.setMethodCallHandler(this)

        stepCounts = EventChannel(binding.binaryMessenger, STEP_COUNTS)
        stepCounts.setStreamHandler(
            SensorStreamHandler(sensors, Sensor.TYPE_STEP_COUNTER, main)
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        stepCounts.setStreamHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isStepCountingAvailable" ->
                result.success(sensors.getDefaultSensor(Sensor.TYPE_STEP_COUNTER) != null)

            "readStepCount" -> readStepCount(result)

            else -> result.notImplemented()
        }
    }

    /**
     * One reading, then unregister.
     *
     * `TYPE_STEP_COUNTER` is an on-change sensor, so the platform delivers the
     * current value on registration — no walking required. That is what lets a
     * periodic sampler get an accurate count without ever holding a
     * subscription open.
     */
    private fun readStepCount(result: MethodChannel.Result) {
        val sensor = sensors.getDefaultSensor(Sensor.TYPE_STEP_COUNTER)
        if (sensor == null) {
            result.success(null)
            return
        }

        var settled = false
        var timeout: Runnable? = null

        val listener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                if (settled) return
                settled = true
                sensors.unregisterListener(this)
                timeout?.let { main.removeCallbacks(it) }
                result.success(readingOf(event))
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
        }

        timeout = Runnable {
            if (settled) return@Runnable
            settled = true
            sensors.unregisterListener(listener)
            result.success(null)
        }
        main.postDelayed(timeout, ONE_SHOT_TIMEOUT_MS)

        // Delivered on the main looper so the Result is answered on the thread
        // the method channel expects.
        sensors.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_FASTEST, main)
    }
}

internal fun readingOf(event: SensorEvent): Map<String, Any> = mapOf(
    "steps" to event.values[0].toLong(),
    "timestamp" to SensorClock.toEpochMillis(event.timestamp),
)

/**
 * Streams one sensor, with the caller's batching.
 *
 * `batchLatencyMicros` is `maxReportLatencyUs`: how long the sensor hub may
 * buffer events in its hardware FIFO before waking the application processor.
 * Zero wakes it per event, which is what makes a live notification feel live
 * and what makes an always-on subscription expensive.
 */
internal class SensorStreamHandler(
    private val sensors: SensorManager,
    private val sensorType: Int,
    private val handler: Handler,
) : EventChannel.StreamHandler {

    private var listener: SensorEventListener? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        val sensor = sensors.getDefaultSensor(sensorType)
        if (sensor == null) {
            events.error("no_sensor", "This device has no sensor of type $sensorType", null)
            return
        }

        @Suppress("UNCHECKED_CAST")
        val args = arguments as? Map<String, Any?>
        val batchLatencyMicros = (args?.get("batchLatencyMicros") as? Number)?.toInt() ?: 0

        val sensorListener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) = events.success(readingOf(event))
            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
        }
        listener = sensorListener

        sensors.registerListener(
            sensorListener,
            sensor,
            SensorManager.SENSOR_DELAY_FASTEST,
            batchLatencyMicros,
            handler,
        )
    }

    override fun onCancel(arguments: Any?) {
        listener?.let { sensors.unregisterListener(it) }
        listener = null
    }
}
