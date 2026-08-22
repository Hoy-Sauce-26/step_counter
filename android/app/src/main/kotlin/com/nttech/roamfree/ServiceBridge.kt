package com.nttech.roamfree

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/**
 * Routes messages between the UI isolate and the tracking service's isolate.
 *
 * Each side registers its own channel when its engine comes up. A message with
 * no live counterpart is dropped rather than queued: if the app isn't running
 * there is nobody to receive a report, and if the service isn't running a
 * command has nothing to act on.
 */
object ServiceBridge {
    private val main = Handler(Looper.getMainLooper())

    private var serviceChannel: MethodChannel? = null
    private var uiChannel: MethodChannel? = null

    fun attachService(channel: MethodChannel?) {
        serviceChannel = channel
    }

    fun attachUi(channel: MethodChannel?) {
        uiChannel = channel
    }

    fun toService(method: String, args: Any?) = dispatch(serviceChannel, method, args)

    fun toUi(method: String, args: Any?) = dispatch(uiChannel, method, args)

    /** Always on the main looper — a MethodChannel may only be invoked there. */
    private fun dispatch(channel: MethodChannel?, method: String, args: Any?) {
        val target = channel ?: return
        main.post {
            target.invokeMethod("onMessage", mapOf("method" to method, "args" to args))
        }
    }
}
