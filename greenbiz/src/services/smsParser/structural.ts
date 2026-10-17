import { inferCurrency, normalizeDigits, parseAmountMinor } from "./patterns/shared";
import type { SmsExtract, SmsProvider, SupportedCurrency } from "./types";

/**
 * Structural SMS parsing.
 *
 * The provider templates in `patterns/` describe *one* wording each. Mobile
 * money companies change those words regularly, so this parser looks for the
 * structure that every payment confirmation shares instead:
 *
 *   [provider words] [direction phrase] [currency amount] [counterparty]
 *   [TrxID] [fee] [balance]
 *
 * Amounts are scored by the label before them, so a balance or fee is never
 * mistaken for the payment. Direction is scored by the words around the
 * amount, so "Payment received" and "Payment of Tk ... to" cannot collapse
 * into the same result.
 *
 * It intentionally returns null rather than guessing when there is no amount,
 * no transaction signal, or the message is an OTP.
 */

export interface StructuralParse {
	provider: SmsProvider;
	extract: SmsExtract;
	currency: SupportedCurrency | null;
	confidence: number;
	detail: string;
}

interface AmountCandidate {
	index: number;
	end: number;
	raw: string;
	minor: number;
	score: number;
	hasCurrency: boolean;
}

const TRX_ID = /\b(?:trx|txn|transaction)\s*id\b\s*[:#.-]?\s*([a-z0-9][a-z0-9._-]{2,62}[a-z0-9])/i;
const FALLBACK_REF = /\b(?:reference|ref)\s*(?:no|id)?\s*[:#.-]?\s*([a-z0-9][a-z0-9._-]{2,62}[a-z0-9])/i;

const OTP_WORDS =
	/\b(?:otp|one[\s-]*time\s*(?:password|pin)|verification\s*code|do\s+not\s+share|security\s*code)\b/i;
const PROMO_WORDS =
	/\b(?:cashback|promo|promotion|offer|discount|coupon|winner|prize|lottery|apply\s+now|loan\s+offer)\b/i;

const TRANSACTION_SIGNAL =
	/\b(?:received?|receiving|credited|deposited?|added|sent|send|paid|payment|pay|collection|cash[\s-]*(?:in|out)|recharge|bill\s*pay|transfer(?:red)?|debited?|withdrawn?|withdraw|merchant|trx\s*id|trxid|txn\s*id|transaction\s*id)\b/i;

const INFLOW_RULES: ReadonlyArray<readonly [RegExp, number]> = [
	[/\bmerchant\s+(?:pay|payment)\s+received\b/, 8],
	[/\bpayment\s+received\b/, 7],
	[/\breceived\s+payment\b/, 7],
	[/\bcollection\s+of\b/, 7],
	[/\bcash[\s-]*in\b/, 7],
	[/\badd(?:ed)?\s+money\b/, 7],
	[/\badded\s+to\s+(?:your\s+)?(?:account|wallet)\b/, 7],
	[/\b(?:money\s+)?received\b/, 6],
	[/\b(?:you\s+have\s+)?received?\b/, 6],
	[/\breceived\s+from\b/, 6],
	[/\bcredited\b/, 6],
	[/\bdeposited?\b/, 6],
];

const OUTFLOW_RULES: ReadonlyArray<readonly [RegExp, number]> = [
	[/\bsent\s+money\b/, 8],
	[/\bmerchant\s+(?:pay|payment)\s+of\b/, 8],
	[/\b(?:you\s+have\s+)?sent\b/, 7],
	[/\bcash[\s-]*out\b/, 7],
	[/\b(?:mobile\s+)?recharge\b/, 7],
	[/\bbill\s*pay(?:ment)?\b/, 7],
	[/\btransfer(?:red)?\b/, 7],
	[/\b(?:you\s+have\s+)?paid\b/, 7],
	[/\bpayment\s+(?:of|tk|bdt|taka|৳|rs|inr)\b/, 6],
	[/\bdebited\b/, 6],
	[/\bwithdrawn?\b/, 6],
	[/\bpurchase\b/, 5],
];

const COUNTERPARTY_STOP =
	/(?:successful|success|failed|failure|completed|trx|txn|transaction\s*id|fee|balance|date|store\s*id|counter|reference|ref\b|at\s+\d|through|via)/i;

const EXCLUDED_AMOUNT_LABEL =
	/(?:balance|available|current|total|opening|previous|wallet|merchant\s+balance|fee|charge|limit|due)\s*(?:is\s*)?[:=]?\s*$/i;

/** True when the text looks like a payment rather than an OTP or promotion. */
export function isStructuralPaymentCandidate(sender: string, body: string): boolean {
	const text = normalizeDigits(body);
	if (OTP_WORDS.test(text)) return false;
	if (!TRANSACTION_SIGNAL.test(text)) return false;

	// A known provider sender is enough. An unknown sender must at least carry
	// a transaction id or a provider brand in the body, so a personal
	// "I received Tk 500 from you" never becomes a ledger row.
	if (!TRX_ID.test(text) && providerMention(text) === "unknown" && !senderLooksKnown(sender)) {
		return false;
	}

	return extractAmount(text) !== null;
}

/** Brand words that survive a changed sender id. */
export function providerMention(text: string): SmsProvider {
	const lower = text.toLowerCase();
	if (/\bbkash\b/.test(lower)) return "bkash";
	if (/\bnagad\b/.test(lower)) return "nagad";
	if (/\b(?:rocket|dbbl|dutch\s*bangla)\b/.test(lower)) return "rocket";
	if (/\b(?:upay|ucb)\b/.test(lower)) return "upay";
	if (/\b(?:upi|paytm|phonepe|gpay|bhim|inr|rs\.?\s*\d)\b/.test(lower)) return "upi";
	return "unknown";
}

function senderLooksKnown(sender: string): boolean {
	const normalized = sender.toLowerCase().replace(/[^a-z0-9]/g, "");
	return (
		normalized === "16247" ||
		normalized === "16167" ||
		normalized === "16248" ||
		normalized === "16222" ||
		normalized === "16216" ||
		normalized === "16218" ||
		normalized === "16268" ||
		/^(?:bkash|nagad|rocket|dbbl|upay|ucb)/.test(normalized) ||
		/(?:hdfcbk|sbiinb|icicib|axisbk|kotakb|pnb|paytm|phonepe|gpay|ybl|bhim)$/.test(normalized)
	);
}

/** Runs the structural parser. Returns null when the message is not a payment. */
export function parseSmsStructurally(
	sender: string,
	rawBody: string,
	provider: SmsProvider,
): StructuralParse | null {
	const body = normalizeDigits(rawBody).replace(/\u00a0/g, " ");
	if (OTP_WORDS.test(body)) return null;
	if (PROMO_WORDS.test(body) && !TRX_ID.test(body)) return null;
	if (!TRANSACTION_SIGNAL.test(body)) return null;

	const detected = provider === "unknown" ? providerMention(body) : provider;
	if (detected === "unknown" && !TRX_ID.test(body)) return null;

	const amount = extractAmount(body);
	if (!amount) return null;

	const direction = decideDirection(body, amount);
	const reference = extractReference(body);
	const counterparty = extractCounterparty(body, amount, direction);

	return {
		provider: detected,
		currency: inferCurrency(body, detected === "unknown" ? null : currencyForProvider(detected)),
		extract: {
			direction,
			amountMinor: amount.minor,
			...(counterparty === undefined ? {} : { counterparty }),
			...(reference === undefined ? {} : { reference }),
		},
		confidence: directionConfidence(body) >= 3 ? 0.92 : 0.8,
		detail: "structural.v1",
	};
}

function currencyForProvider(provider: Exclude<SmsProvider, "unknown">): SupportedCurrency {
	return provider === "upi" ? "INR" : "BDT";
}

/**
 * Finds every money-looking number, throws away balances and fees, and scores
 * the rest by how closely they sit to a transaction word.
 */
function extractAmount(body: string): AmountCandidate | null {
	const candidates = new Map<number, AmountCandidate>();

	const currencyFirst = /(?:tk\.?|bdt|taka|৳|rs\.?|inr|₹)\s*\.?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)(?![0-9]|\.[0-9])/gi;
	const currencyLast = /([0-9][0-9,]*(?:\.[0-9]{1,2})?)(?![0-9]|\.[0-9])\s*(?:tk\.?|bdt|taka|rs\.?|inr|৳|₹)/gi;
	const labeled = /(?:amount|paid|received|sent|collection|cash\s*(?:in|out)|recharge|bill\s*pay|transfer|payment)\s*(?:of|is|:)?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)(?![0-9]|\.[0-9])/gi;

	for (const [regex, hasCurrency] of [
		[currencyFirst, true],
		[currencyLast, true],
		[labeled, false],
	] as const) {
		for (const match of body.matchAll(regex)) {
			const raw = match[1];
			if (raw === undefined) continue;

			const matchIndex = match.index ?? 0;
			const index = matchIndex + match[0].indexOf(raw);
			const minor = parseAmountMinor(raw);
			if (!Number.isFinite(minor) || minor <= 0) continue;

			const before = body.slice(Math.max(0, index - 44), index).toLowerCase();
			if (EXCLUDED_AMOUNT_LABEL.test(before.replace(/[:\s]+$/, " "))) continue;

			const after = body.slice(index + raw.length, index + raw.length + 56).toLowerCase();
			let score = 0;

			if (/(?:amount|received?|credited|deposited|added\s*to|collection|cash\s*in|add\s*money)/.test(before)) {
				score += 4;
			}
			if (/(?:payment|paid|sent|send|cash\s*out|recharge|bill\s*pay|transfer|merchant)/.test(before)) {
				score += 2;
			}
			if (/^\s*(?:to|from)\b/.test(after)) score += 2;
			if (/(?:added\s+to|credited|deposited|received)/.test(after)) score += 4;

			// A bare number only counts when a transaction word introduced it.
			if (!hasCurrency && score === 0) continue;

			const existing = candidates.get(index);
			if (existing && existing.score >= score) continue;
			candidates.set(index, {
				index,
				end: index + raw.length,
				raw,
				minor,
				score,
				hasCurrency,
			});
		}
	}

	if (candidates.size === 0) return null;

	return [...candidates.values()].sort((a, b) => b.score - a.score || a.index - b.index)[0] ?? null;
}

function decideDirection(body: string, amount: AmountCandidate): "in" | "out" {
	const lower = body.toLowerCase();
	let inflow = 0;
	let outflow = 0;

	for (const [regex, weight] of INFLOW_RULES) if (regex.test(lower)) inflow += weight;
	for (const [regex, weight] of OUTFLOW_RULES) if (regex.test(lower)) outflow += weight;

	// The words immediately after the amount are the strongest signal:
	// "Tk 1,200.00 to Aarong" is outgoing, "Tk 1,200.00 from 017..." is incoming.
	const after = lower.slice(amount.end, amount.end + 90);
	const fromAt = after.search(/\bfrom\b/);
	const toAt = after.search(/\bto\b/);
	if (fromAt >= 0 && (toAt < 0 || fromAt < toAt)) inflow += 3;
	if (toAt >= 0 && (fromAt < 0 || toAt < fromAt)) outflow += 3;

	if (inflow === outflow) {
		// A payment confirmation with no direction words is far more likely to
		// be money in for a merchant than a mystery outflow.
		return "in";
	}
	return inflow > outflow ? "in" : "out";
}

function directionConfidence(body: string): number {
	const lower = body.toLowerCase();
	let score = 0;
	for (const [regex, weight] of INFLOW_RULES) if (regex.test(lower)) score += weight;
	for (const [regex, weight] of OUTFLOW_RULES) if (regex.test(lower)) score += weight;
	return score;
}

function extractReference(body: string): string | undefined {
	const primary = TRX_ID.exec(body)?.[1];
	if (primary) return primary.toUpperCase();

	const fallback = FALLBACK_REF.exec(body)?.[1];
	if (fallback) return fallback.toUpperCase();

	return undefined;
}

function extractCounterparty(
	body: string,
	amount: AmountCandidate,
	direction: "in" | "out",
): string | undefined {
	const after = body.slice(amount.end, amount.end + 180);
	const candidates: string[] = [];

	if (direction === "in") {
		const from = /\bfrom\s+(?:(?:agent|customer|merchant|account)\s+)?([A-Za-z0-9][^.\n]{1,70})/i.exec(after);
		if (from?.[1]) candidates.push(from[1]);
	} else {
		const to = /\bto\s+([A-Za-z0-9][^.\n]{1,70})/i.exec(after);
		if (to?.[1]) candidates.push(to[1]);

		const organization = /\b(?:organization|biller|merchant)\s*[:#-]?\s*([A-Za-z0-9][^.\n]{1,70})/i.exec(body);
		if (organization?.[1]) candidates.push(organization[1]);
	}

	const agent = /\b(?:agent|through\s+agent)\s*[:#-]?\s*([0-9Xx*][0-9Xx*\s-]{5,30})/i.exec(body);
	if (agent?.[1]) candidates.push(agent[1]);

	for (const candidate of candidates) {
		const cleaned = cleanCounterparty(candidate);
		if (cleaned) return cleaned;
	}
	return undefined;
}

function cleanCounterparty(raw: string): string | undefined {
	const stopMatch = COUNTERPARTY_STOP.exec(raw);
	const value = (stopMatch ? raw.slice(0, stopMatch.index) : raw)
		.replace(/^[\s:,-]+/, "")
		.replace(/[\s:;,.!-]+$/, "")
		.trim();

	if (value.length < 2) return undefined;
	if (/^(?:your\s+)?(?:account|a\/c|wallet|card)$/i.test(value)) return undefined;

	return value.slice(0, 120);
}
