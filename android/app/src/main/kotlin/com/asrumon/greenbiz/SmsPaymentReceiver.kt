package com.asrumon.greenbiz

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Telephony

/**
 * Receives payment confirmations as they arrive.
 *
 * Only messages from known mobile-money / bank senders that read as incoming
 * payments are kept. Everything else is discarded before it is stored, so a
 * personal message or an OTP never enters the app's own queue.
 */
class SmsPaymentReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return

        // Nobody is signed in: do not record or alert.
        if (!PaymentSmsStore.isEnabled(context)) return

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            context.checkSelfPermission(Manifest.permission.RECEIVE_SMS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }

        val parts = Telephony.Sms.Intents.getMessagesFromIntent(intent)

        // Multipart messages arrive as several PDUs with the same sender and
        // timestamp. Join them before parsing, or an amount split across parts
        // would be missed.
        val grouped = parts
            .filter { !it.originatingAddress.isNullOrBlank() && !it.messageBody.isNullOrBlank() }
            .groupBy { (it.originatingAddress ?: "") to it.timestampMillis }

        for ((key, messages) in grouped) {
            val sender = key.first
            val receivedAt = key.second
            val body = messages.joinToString(separator = "") { it.messageBody ?: "" }

            val payment = PaymentSms.parse(sender, body, receivedAt) ?: continue

            if (SmsLiveBridge.isForeground && SmsLiveBridge.sink != null) {
                // The owner is looking at the app: show the sheet, and do not
                // also queue it for the next resume.
                SmsLiveBridge.emit(payment)
            } else {
                // Queue first, then notify. If the process dies after this
                // point the message is still waiting on the next launch.
                PaymentSmsStore.add(context, payment)
                SmsNotification.show(context, payment)
            }
        }
    }
}
