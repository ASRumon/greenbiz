package com.asrumon.greenbiz

import org.json.JSONObject
import java.util.UUID

/**
 * One incoming payment confirmation, parsed far enough to decide whether to
 * alert the owner.
 *
 * The Worker still parses the message authoritatively when it is uploaded. This
 * local copy exists so the phone can react immediately and so the alert can
 * show an amount before any network call happens.
 */
data class PaymentSms(
    val id: String,
    val sender: String,
    val body: String,
    val receivedAt: Long,
    val amountMinor: Long,
    val method: String,
    val reference: String?,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "id" to id,
        "sender" to sender,
        "body" to body,
        "receivedAt" to receivedAt,
        "amountMinor" to amountMinor,
        "method" to method,
        "reference" to reference,
        "isInflow" to true,
    )

    fun toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("sender", sender)
        .put("body", body)
        .put("receivedAt", receivedAt)
        .put("amountMinor", amountMinor)
        .put("method", method)
        .put("reference", reference ?: JSONObject.NULL)

    companion object {
        private val paymentSenderIds = listOf(
            // bKash, Nagad (16167 current, 16248 legacy), Rocket/DBBL
            // (16222 current, 16216/16218 legacy), Upay.
            "16247", "bkash",
            "16167", "16248", "nagad",
            "16222", "16216", "16218", "rocket", "dbbl",
            "16268", "upay", "ucb",
            // India: bank and PSP headers
            "hdfcbk", "sbiinb", "icicib", "axisbk", "kotakb",
            "pnb", "bob", "paytm", "phonepe", "gpay", "ybl", "bhim",
        )

        private val otpWords = Regex(
            """\b(?:otp|one[\s-]*time\s*(?:password|pin)|verification\s*code|do\s+not\s+share|security\s*code)\b""",
            RegexOption.IGNORE_CASE,
        )
        private val promoWords = Regex(
            """\b(?:cashback|promo|promotion|offer|discount|coupon|winner|prize|lottery|apply\s+now|loan\s+offer)\b""",
            RegexOption.IGNORE_CASE,
        )
        private val transactionSignal = Regex(
            """\b(?:received?|receiving|credited|deposited?|added|sent|send|paid|payment|pay|collection|cash[\s-]*(?:in|out)|recharge|bill\s*pay|transfer(?:red)?|debited?|withdrawn?|withdraw|merchant|trx\s*id|trxid|txn\s*id|transaction\s*id)\b""",
            RegexOption.IGNORE_CASE,
        )
        private val trxId = Regex(
            """\b(?:trx|txn|transaction)\s*id\b\s*[:#.-]?\s*([a-z0-9][a-z0-9._-]{2,62}[a-z0-9])""",
            RegexOption.IGNORE_CASE,
        )
        private val fallbackRef = Regex(
            """\b(?:reference|ref)\s*(?:no|id)?\s*[:#.-]?\s*([a-z0-9][a-z0-9._-]{2,62}[a-z0-9])""",
            RegexOption.IGNORE_CASE,
        )
        private val receivedSignal = Regex(
            """\b(?:received?|credited|deposited?|collection|cash[\s-]*in|add(?:ed)?\s*money|merchant\s+(?:pay|payment)\s+received)\b""",
            RegexOption.IGNORE_CASE,
        )

        private val amountFirst = Regex(
            """(?:tk\.?|bdt|taka|৳|rs\.?|inr|₹)\s*\.?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)(?![0-9]|\.[0-9])""",
            RegexOption.IGNORE_CASE,
        )
        private val amountLast = Regex(
            """([0-9][0-9,]*(?:\.[0-9]{1,2})?)(?![0-9]|\.[0-9])\s*(?:tk\.?|bdt|taka|rs\.?|inr|৳|₹)""",
            RegexOption.IGNORE_CASE,
        )
        private val amountLabeled = Regex(
            """(?:amount|paid|received|sent|collection|cash\s*(?:in|out)|recharge|bill\s*pay|transfer|payment)\s*(?:of|is|:)?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)(?![0-9]|\.[0-9])""",
            RegexOption.IGNORE_CASE,
        )
        private val excludedAmountLabel = Regex(
            """(?:balance|available|current|total|opening|previous|wallet|merchant\s+balance|fee|charge|limit|due)\s*(?:is\s*)?[:=]?\s*$""",
            RegexOption.IGNORE_CASE,
        )

        private val inflowRules = listOf(
            Regex("""\bmerchant\s+(?:pay|payment)\s+received\b""", RegexOption.IGNORE_CASE) to 8,
            Regex("""\bpayment\s+received\b""", RegexOption.IGNORE_CASE) to 7,
            Regex("""\breceived\s+payment\b""", RegexOption.IGNORE_CASE) to 7,
            Regex("""\bcollection\s+of\b""", RegexOption.IGNORE_CASE) to 7,
            Regex("""\bcash[\s-]*in\b""", RegexOption.IGNORE_CASE) to 7,
            Regex("""\badd(?:ed)?\s+money\b""", RegexOption.IGNORE_CASE) to 7,
            Regex("""\badded\s+to\s+(?:your\s+)?(?:account|wallet)\b""", RegexOption.IGNORE_CASE) to 7,
            Regex("""\b(?:money\s+)?received\b""", RegexOption.IGNORE_CASE) to 6,
            Regex("""\b(?:you\s+have\s+)?received?\b""", RegexOption.IGNORE_CASE) to 6,
            Regex("""\breceived\s+from\b""", RegexOption.IGNORE_CASE) to 6,
            Regex("""\bcredited\b""", RegexOption.IGNORE_CASE) to 6,
            Regex("""\bdeposited?\b""", RegexOption.IGNORE_CASE) to 6,
        )
        private val outflowRules = listOf(
            Regex("""\bsent\s+money\b""", RegexOption.IGNORE_CASE) to 8,
            Regex("""\bmerchant\s+(?:pay|payment)\s+of\b""", RegexOption.IGNORE_CASE) to 8,
            Regex("""\b(?:you\s+have\s+)?sent\b""", RegexOption.IGNORE_CASE) to 7,
            Regex("""\bcash[\s-]*out\b""", RegexOption.IGNORE_CASE) to 7,
            Regex("""\b(?:mobile\s+)?recharge\b""", RegexOption.IGNORE_CASE) to 7,
            Regex("""\bbill\s*pay(?:ment)?\b""", RegexOption.IGNORE_CASE) to 7,
            Regex("""\btransfer(?:red)?\b""", RegexOption.IGNORE_CASE) to 7,
            Regex("""\b(?:you\s+have\s+)?paid\b""", RegexOption.IGNORE_CASE) to 7,
            Regex("""\bpayment\s+(?:of|tk|bdt|taka|৳|rs|inr)\b""", RegexOption.IGNORE_CASE) to 6,
            Regex("""\bdebited\b""", RegexOption.IGNORE_CASE) to 6,
            Regex("""\bwithdrawn?\b""", RegexOption.IGNORE_CASE) to 6,
            Regex("""\bpurchase\b""", RegexOption.IGNORE_CASE) to 5,
        )

        /**
         * Returns an incoming payment, or null when the message is not one.
         *
         * This mirrors the Worker's structural parser. It is intentionally
         * independent of any provider's exact wording so a changed template
         * still produces an alert.
         */
        fun parse(sender: String, body: String, receivedAt: Long): PaymentSms? {
            if (sender.isBlank() || body.isBlank()) return null

            val text = normalizeDigits(body)
            if (otpWords.containsMatchIn(text)) return null
            if (promoWords.containsMatchIn(text) && !trxId.containsMatchIn(text)) return null
            if (!transactionSignal.containsMatchIn(text)) return null

            val method = detectMethod(sender, text)
            if (!isPaymentSender(sender) && method == "other") return null
            if (!isPaymentSender(sender) &&
                !trxId.containsMatchIn(text) &&
                !receivedSignal.containsMatchIn(text)
            ) {
                return null
            }

            val amount = extractAmount(text) ?: return null
            if (amount.minor <= 0) return null
            if (!decideDirection(text, amount)) return null

            val reference = trxId.find(text)?.groupValues?.getOrNull(1)?.uppercase()
                ?: fallbackRef.find(text)?.groupValues?.getOrNull(1)?.uppercase()

            return PaymentSms(
                id = UUID.randomUUID().toString(),
                sender = sender,
                body = body,
                receivedAt = receivedAt,
                amountMinor = amount.minor,
                method = method,
                reference = reference,
            )
        }

        fun fromJson(json: JSONObject): PaymentSms = PaymentSms(
            id = json.optString("id"),
            sender = json.optString("sender"),
            body = json.optString("body"),
            receivedAt = json.optLong("receivedAt"),
            amountMinor = json.optLong("amountMinor"),
            method = json.optString("method", "other"),
            reference = if (json.isNull("reference")) null else json.optString("reference").takeIf { it.isNotBlank() },
        )

        private fun isPaymentSender(sender: String): Boolean {
            val normalized = sender.lowercase().replace(Regex("[^a-z0-9]"), "")
            if (normalized.isEmpty()) return false
            return paymentSenderIds.any { normalized == it || normalized.endsWith(it) }
        }

        private fun detectMethod(sender: String, body: String): String {
            val normalized = sender.lowercase().replace(Regex("[^a-z0-9]"), "")
            val text = body.lowercase()
            return when {
                normalized == "16247" ||
                    normalized.startsWith("bkash") ||
                    text.contains("bkash") -> "bkash"
                normalized == "16167" ||
                    normalized == "16248" ||
                    normalized.startsWith("nagad") ||
                    text.contains("nagad") -> "nagad"
                normalized == "16222" ||
                    normalized == "16216" ||
                    normalized == "16218" ||
                    normalized.startsWith("rocket") ||
                    normalized.startsWith("dbbl") ||
                    text.contains("rocket") ||
                    text.contains("dbbl") -> "rocket"
                normalized == "16268" ||
                    normalized.startsWith("upay") ||
                    normalized.startsWith("ucb") ||
                    Regex("""\b(?:upay|ucb)\b""").containsMatchIn(text) -> "upay"
                Regex(
                    """(?:hdfcbk|sbiinb|icicib|axisbk|kotakb|pnb|bob|paytm|phonepe|gpay|ybl|bhim)$""",
                ).containsMatchIn(normalized) ||
                    Regex("""\b(?:upi|paytm|phonepe|gpay|bhim|inr|rs\.?\s*\d)\b""").containsMatchIn(text) -> "upi"
                else -> "other"
            }
        }

        private fun normalizeDigits(input: String): String {
            val buffer = StringBuilder(input.length)
            for (char in input) {
                buffer.append(
                    when (char.code) {
                        in 0x09e6..0x09ef -> ('0' + (char.code - 0x09e6))
                        in 0x0966..0x096f -> ('0' + (char.code - 0x0966))
                        else -> char
                    },
                )
            }
            return buffer.toString()
        }

        private fun extractAmount(body: String): AmountCandidate? {
            val candidates = linkedMapOf<Int, AmountCandidate>()

            fun collect(regex: Regex, hasCurrency: Boolean) {
                for (match in regex.findAll(body)) {
                    val raw = match.groupValues.getOrNull(1) ?: continue
                    val index = match.range.first + match.value.indexOf(raw)
                    val minor = parseMinor(raw) ?: continue
                    if (minor <= 0) continue

                    val before = body.substring(maxOf(0, index - 44), index).lowercase()
                        .replace(Regex(""":[\\s]+$"""), " ")
                    if (excludedAmountLabel.containsMatchIn(before)) continue

                    val after = body.substring(
                        index + raw.length,
                        minOf(body.length, index + raw.length + 56),
                    ).lowercase()

                    var score = 0
                    if (Regex(
                            """(?:amount|received?|credited|deposited|added\s*to|collection|cash\s*in|add\s*money)""",
                        ).containsMatchIn(before)
                    ) score += 4
                    if (Regex(
                            """(?:payment|paid|sent|send|cash\s*out|recharge|bill\s*pay|transfer|merchant)""",
                        ).containsMatchIn(before)
                    ) score += 2
                    if (Regex("""^\s*(?:to|from)\b""").containsMatchIn(after)) score += 2
                    if (Regex(
                            """(?:added\s+to|credited|deposited|received)""",
                        ).containsMatchIn(after)
                    ) score += 4

                    if (!hasCurrency && score == 0) continue

                    val existing = candidates[index]
                    if (existing != null && existing.score >= score) continue
                    candidates[index] = AmountCandidate(index, index + raw.length, minor, score)
                }
            }

            collect(amountFirst, true)
            collect(amountLast, true)
            collect(amountLabeled, false)

            return candidates.values
                .sortedWith(
                    compareByDescending<AmountCandidate> { it.score }.thenBy { it.index },
                )
                .firstOrNull()
        }

        private fun parseMinor(raw: String): Long? {
            val cleaned = raw.replace(",", "").trim()
            if (cleaned.isEmpty()) return null

            val parts = cleaned.split(".")
            val whole = parts.getOrNull(0)?.toLongOrNull() ?: return null
            val fraction = parts.getOrNull(1)?.padEnd(2, '0')?.take(2)?.toLongOrNull() ?: 0L
            return whole * 100 + fraction
        }

        private fun decideDirection(text: String, amount: AmountCandidate): Boolean {
            val lower = text.lowercase()
            var inflow = 0
            var outflow = 0

            for ((regex, weight) in inflowRules) if (regex.containsMatchIn(lower)) inflow += weight
            for ((regex, weight) in outflowRules) if (regex.containsMatchIn(lower)) outflow += weight

            val after = lower.substring(amount.end, minOf(lower.length, amount.end + 90))
            val fromAt = Regex("""\bfrom\b""").find(after)?.range?.first ?: -1
            val toAt = Regex("""\bto\b""").find(after)?.range?.first ?: -1
            if (fromAt >= 0 && (toAt < 0 || fromAt < toAt)) inflow += 3
            if (toAt >= 0 && (fromAt < 0 || toAt < fromAt)) outflow += 3

            // A payment confirmation with no direction words is far more likely
            // to be money in for a merchant. Outflows still win when their
            // verbs are present.
            if (inflow == outflow) return true
            return inflow > outflow
        }
    }
}

private data class AmountCandidate(
    val index: Int,
    val end: Int,
    val minor: Long,
    val score: Int,
)
