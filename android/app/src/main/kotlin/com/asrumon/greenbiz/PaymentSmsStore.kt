package com.asrumon.greenbiz

import android.content.Context
import org.json.JSONArray

/**
 * A small durable queue for confirmations captured while the app was not in
 * the foreground.
 *
 * The receiver writes here before it posts a notification or touches the
 * Flutter engine. If the process dies between the broadcast and the next
 * launch, the message is still waiting to be shown and uploaded.
 */
object PaymentSmsStore {
    private const val PREFERENCES = "greenbiz_live_sms"
    private const val KEY_PENDING = "pending"
    private const val KEY_ENABLED = "tracking_enabled"
    private const val MAX_PENDING = 50

    /**
     * Off while nobody is signed in. The Dart side turns this on when the app
     * shell starts and off again on logout, so a message cannot be queued for
     * (or shown to) the next account.
     */
    @Synchronized
    fun setEnabled(context: Context, enabled: Boolean) {
        // commit() so a sign-out takes effect before the next broadcast.
        preferences(context).edit().putBoolean(KEY_ENABLED, enabled).commit()
    }

    @Synchronized
    fun isEnabled(context: Context): Boolean =
        preferences(context).getBoolean(KEY_ENABLED, false)

    @Synchronized
    fun add(context: Context, sms: PaymentSms) {
        val existing = read(context)
        val duplicate = existing.any {
            it.id == sms.id ||
                (it.sender == sms.sender &&
                    it.body == sms.body &&
                    it.receivedAt == sms.receivedAt)
        }
        if (duplicate) return

        val next = (existing + sms).takeLast(MAX_PENDING)
        write(context, next)
    }

    /** Returns everything queued and clears the queue atomically. */
    @Synchronized
    fun consume(context: Context): List<PaymentSms> {
        val pending = read(context)
        write(context, emptyList())
        return pending
    }

    @Synchronized
    fun clear(context: Context) {
        write(context, emptyList())
    }

    private fun read(context: Context): List<PaymentSms> {
        val raw = preferences(context).getString(KEY_PENDING, null) ?: return emptyList()
        return try {
            val array = JSONArray(raw)
            buildList {
                for (index in 0 until array.length()) {
                    val item = array.optJSONObject(index) ?: continue
                    val parsed = PaymentSms.fromJson(item)
                    if (parsed.sender.isNotBlank() && parsed.body.isNotBlank()) add(parsed)
                }
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun write(context: Context, items: List<PaymentSms>) {
        val array = JSONArray()
        items.forEach { array.put(it.toJson()) }
        // commit(), not apply(): the receiver's process may be killed as soon
        // as onReceive returns, and the message must survive that.
        preferences(context).edit().putString(KEY_PENDING, array.toString()).commit()
    }

    private fun preferences(context: Context) =
        context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
}
