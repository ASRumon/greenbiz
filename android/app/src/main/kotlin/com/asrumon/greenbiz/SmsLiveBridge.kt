package com.asrumon.greenbiz

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * The one place the broadcast receiver and the Flutter engine meet.
 *
 * A sink only exists while the engine is alive. If it is null the message has
 * already been queued, and the Dart side drains that queue on the next resume.
 */
object SmsLiveBridge {
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    var sink: EventChannel.EventSink? = null

    /** True while MainActivity is resumed, i.e. the owner can see a prompt. */
    @Volatile
    var isForeground: Boolean = false

    fun emit(sms: PaymentSms) {
        mainHandler.post { sink?.success(sms.toMap()) }
    }
}
