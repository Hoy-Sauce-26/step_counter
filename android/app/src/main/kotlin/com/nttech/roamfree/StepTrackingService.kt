package com.nttech.roamfree

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.FlutterCallbackInformation

/**
 * Runs the step-counting isolate for as long as tracking is on.
 *
 * Deliberately holds **no wakelock**. A foreground service keeps the process
 * from being reclaimed; it does not, and should not, keep the CPU awake. The
 * step counter is a hardware register that keeps counting through suspend and
 * delivers what it buffered when the device next wakes, so nothing is lost by
 * letting the application processor sleep — only the notification lags until
 * it does wake, which is the trade this service exists to make.
 */
class StepTrackingService : Service(), MethodChannel.MethodCallHandler {

    companion object {
        /** Must match NotificationService.channelId in Dart. Never change it. */
        const val CHANNEL_ID = "step_counter_channel"
        const val NOTIFICATION_ID = 888

        private const val METHOD_CHANNEL = "com.nttech.roamfree/service_bg"

        @Volatile
        var isRunning: Boolean = false
            private set

        fun start(context: Context) {
            val intent = Intent(context, StepTrackingService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }

    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        // Within a few seconds of starting or Android kills us, so this comes
        // before any engine work.
        createNotificationChannel()
        goForeground(getString(R.string.app_name), "Starting…")
        startEngine()
    }

    /**
     * START_STICKY rather than the alarm-driven watchdog the old plugin used:
     * Android itself restarts a sticky service it had to kill, with no exact
     * alarms and no polling. The restart arrives with a null Intent, which is
     * why the entrypoint handle is read from storage rather than the Intent.
     */
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (engine == null) startEngine()
        return START_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        ServiceBridge.attachService(null)
        channel?.setMethodCallHandler(null)
        channel = null
        engine?.destroy()
        engine = null
        super.onDestroy()
    }

    private fun startEngine() {
        if (engine != null) return

        val handle = TrackingCallback.read(this)
        if (handle == 0L) {
            // Nothing to run — the app has never launched to register its
            // entrypoint. Stop rather than sit in the notification shade
            // pretending to count.
            stopSelf()
            return
        }

        // Before the lookup, not after: looking a callback up is a native call,
        // and on a cold start — a reboot, or Android restarting us after a
        // kill — this service is the first thing in the process, so nothing
        // has loaded libflutter yet. Starting from the activity happens to
        // work either way, which is what makes this the failure mode you only
        // see once the service has to come up on its own.
        val loader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) loader.startInitialization(applicationContext)
        loader.ensureInitializationComplete(applicationContext, null)

        val callback = FlutterCallbackInformation.lookupCallbackInformation(handle)
        if (callback == null) {
            stopSelf()
            return
        }

        // Default constructor registers GeneratedPluginRegistrant, which is how
        // roameter, sqflite and the rest reach this isolate.
        val created = FlutterEngine(applicationContext)
        engine = created

        channel = MethodChannel(created.dartExecutor.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
            ServiceBridge.attachService(it)
        }

        created.dartExecutor.executeDartCallback(
            DartExecutor.DartCallback(assets, loader.findAppBundlePath(), callback)
        )
        isRunning = true
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // A report bound for the UI isolate.
            "sendToUi" -> {
                ServiceBridge.toUi(
                    call.argument<String>("method") ?: return result.success(false),
                    call.argument<Any>("args"),
                )
                result.success(true)
            }

            "stopService" -> {
                stopSelf()
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        // Created here as well as in Dart because the service can start on
        // boot, before any Dart has run. Creating one that exists is a no-op.
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Step tracking",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Ongoing daily step counter notification"
            }
        )
    }

    private fun goForeground(title: String, content: String) {
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            buildNotification(title, content),
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_HEALTH
            } else {
                0
            },
        )
    }

    private fun buildNotification(title: String, content: String): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val tapToOpen = PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(content)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(tapToOpen)
            .build()
    }
}
