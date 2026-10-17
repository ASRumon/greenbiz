package com.asrumon.greenbiz

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "greenbiz/sms_live",
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    SmsLiveBridge.sink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    SmsLiveBridge.sink = null
                }
            },
        )

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "greenbiz/sms_live_methods",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "consumePending" -> {
                    val pending = PaymentSmsStore.consume(applicationContext)
                    result.success(pending.map { it.toMap() })
                }
                "clearPending" -> {
                    PaymentSmsStore.clear(applicationContext)
                    result.success(null)
                }
                "setTrackingEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    PaymentSmsStore.setEnabled(applicationContext, enabled)
                    if (!enabled) PaymentSmsStore.clear(applicationContext)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // The Flutter engine can be created while the activity is already
        // resumed (for example after a process restart), so seed the flag.
        SmsLiveBridge.isForeground = true
    }

    override fun onResume() {
        super.onResume()
        SmsLiveBridge.isForeground = true
    }

    override fun onPause() {
        SmsLiveBridge.isForeground = false
        super.onPause()
    }

    override fun onDestroy() {
        eventSink = null
        SmsLiveBridge.sink = null
        SmsLiveBridge.isForeground = false
        super.onDestroy()
    }
}
