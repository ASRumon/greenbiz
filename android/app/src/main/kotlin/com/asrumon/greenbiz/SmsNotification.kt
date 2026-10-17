package com.asrumon.greenbiz

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import java.util.Locale

/**
 * Posts the "new payment" alert when the app is not on screen.
 *
 * Tapping the notification (or its Create sale action) opens the app. The Dart
 * controller drains the queue and shows the same prompt it would have shown
 * live, so there is only one confirmation flow to maintain.
 */
object SmsNotification {
    private const val CHANNEL_ID = "greenbiz_payments"
    private const val CHANNEL_NAME = "Payment alerts"

    fun show(context: Context, sms: PaymentSms) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            // The message is already queued; it will appear on next launch.
            return
        }

        createChannel(context)

        val openApp = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("greenbiz_live_sms", sms.id)
        }

        val pendingIntent = PendingIntent.getActivity(
            context,
            sms.id.hashCode(),
            openApp,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_greenbiz)
            .setContentTitle("${sms.methodLabel()} payment received")
            .setContentText("${amountLabel(sms.amountMinor)} · Tap to create a sale")
            .setStyle(NotificationCompat.BigTextStyle().bigText(sms.body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .addAction(
                R.drawable.ic_stat_greenbiz,
                "Create sale",
                pendingIntent,
            )
            .build()

        try {
            NotificationManagerCompat.from(context).notify(sms.id.hashCode(), notification)
        } catch (_: SecurityException) {
            // Permission was revoked between the check and notify().
        }
    }

    private fun createChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val existing = manager.getNotificationChannel(CHANNEL_ID)
        if (existing != null) return

        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Alerts when a mobile-money payment message arrives"
            },
        )
    }

    private fun amountLabel(minor: Long): String {
        val whole = minor / 100
        val fraction = minor % 100
        return "৳ " + String.format(Locale.US, "%,d.%02d", whole, fraction)
    }

    private fun PaymentSms.methodLabel(): String = when (method) {
        "bkash" -> "bKash"
        "nagad" -> "Nagad"
        "rocket" -> "Rocket"
        "upay" -> "Upay"
        "upi" -> "UPI"
        else -> "Mobile money"
    }
}
