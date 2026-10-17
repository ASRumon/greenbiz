import { z } from "zod";
import { aiCompleteJson } from "../ai";
import { AppError } from "../../lib/errors";
import { bkashBanglaPatterns, bkashPatterns } from "./patterns/bkash";
import { nagadPatterns } from "./patterns/nagad";
import { rocketPatterns } from "./patterns/rocket";
import { upiPatterns } from "./patterns/upi";
import { inferCurrency, normalizeDigits } from "./patterns/shared";
import { parseSmsStructurally, providerMention } from "./structural";
import type { DirectedSmsPattern, ParseOutcome, SmsExtract, SmsProvider, SupportedCurrency } from "./types";

export * from "./types";
export { parseAmountMinor } from "./patterns/shared";

/* -------------------------------------------------------------------------- */
/* Provider detection                                                          */
/* -------------------------------------------------------------------------- */

/**
 * Known sender IDs, lowercased and stripped of separators before comparison.
 *
 * Bangladesh mobile money uses short codes (16247 = bKash, 16248 = Nagad,
 * 16216 = Rocket/DBBL). India has no short code: alerts arrive from bank
 * alphanumeric headers like `VM-HDFCBK`, so the bank suffixes are matched too.
 */
const SENDER_MAP: Record<Exclude<SmsProvider, "unknown">, string[]> = {
	bkash: ["16247", "bkash", "bkashapp"],
	nagad: ["16167", "16248", "nagad", "nagadltd"],
	rocket: ["16222", "16216", "16218", "rocket", "dbbl", "dutchbanglabank"],
	upay: ["16268", "upay", "upaybd", "ucb"],
	upi: [
		"hdfcbk", "sbiinb", "icicib", "axisbk", "kotakb", "pnb", "bob",
		"paytm", "phonepe", "gpay", "ybl", "okhdfcbank", "upiaxisb",
		"upi", "bhim", "amazonpay",
	],
};

/** Default currency per network, used only when the body has no currency word. */
const PROVIDER_CURRENCY: Record<Exclude<SmsProvider, "unknown">, SupportedCurrency> = {
	bkash: "BDT",
	nagad: "BDT",
	rocket: "BDT",
	upay: "BDT",
	upi: "INR",
};

export function detectProvider(sender: string, body: string): SmsProvider {
	const normalizedSender = sender.toLowerCase().replace(/[^a-z0-9]/g, "");

	for (const [provider, ids] of Object.entries(SENDER_MAP) as [
		Exclude<SmsProvider, "unknown">,
		string[],
	][]) {
		// Longest-id-first is unnecessary: the ids within a provider are
		// mutually exclusive, and providers do not share codes.
		if (ids.some((id) => normalizedSender === id || normalizedSender.endsWith(id))) {
			return provider;
		}
	}

	// A brand word in the body survives a changed shortcode or a forwarded
	// message, which is exactly the failure mode that breaks template lists.
	return providerMention(body);
}

/* -------------------------------------------------------------------------- */
/* Tier 1: regex                                                               */
/* -------------------------------------------------------------------------- */

const PATTERNS: Record<Exclude<SmsProvider, "unknown">, DirectedSmsPattern[]> = {
	bkash: [...bkashPatterns, ...bkashBanglaPatterns],
	nagad: nagadPatterns,
	rocket: rocketPatterns,
	// Upay has no dedicated template list: the structural parser handles it,
	// and new Upay wording then needs no code change at all.
	upay: [],
	upi: upiPatterns,
};

const ALL_PATTERN_SETS = Object.values(PATTERNS);

export interface RegexParseResult {
	provider: SmsProvider;
	patternName: string;
	extract: SmsExtract;
}

/**
 * Tier 1. Returns null when no pattern matches.
 *
 * When the provider is known, only that provider's patterns run. When it is
 * unknown, every provider's patterns are tried - mobile-money alerts are often
 * forwarded or arrive from a bank header, and a correct match is worth more
 * than the tidy assumption that the sender id is reliable.
 */
export function parseWithRegex(sender: string, rawBody: string): RegexParseResult | null {
	const body = normalizeDigits(rawBody);
	const detected = detectProvider(sender, body);

	const candidateSets =
		detected === "unknown"
			? ALL_PATTERN_SETS
			: [PATTERNS[detected]];

	for (const patternSet of candidateSets) {
		for (const pattern of patternSet) {
			// `regex` instances are module-level and carry `lastIndex` when
			// global; reset defensively so a previous call cannot skip a match.
			pattern.regex.lastIndex = 0;

			const match = pattern.regex.exec(body);
			if (!match) continue;

			try {
				const extract = pattern.extract(match, { direction: pattern.direction });
				return {
					provider: providerForPattern(pattern.name, detected),
					patternName: pattern.name,
					extract,
				};
			} catch {
				// Structurally matched but the amount was unusable (e.g. three
				// decimal places). Try the next pattern rather than failing.
				continue;
			}
		}
	}

	// Tier 1b: structural parsing. This is what keeps working when a provider
	// changes a word, adds a new template, or launches a new shortcode.
	const structural = parseSmsStructurally(sender, body, detected);
	if (structural) {
		return {
			provider: structural.provider,
			patternName: structural.detail,
			extract: structural.extract,
		};
	}

	return null;
}

function providerForPattern(
	patternName: string,
	detected: SmsProvider,
): Exclude<SmsProvider, "unknown"> {
	const prefix = patternName.split(".")[0];
	if (
		prefix === "bkash" ||
		prefix === "nagad" ||
		prefix === "rocket" ||
		prefix === "upay" ||
		prefix === "upi"
	) {
		return prefix;
	}
	return detected === "unknown" ? "bkash" : detected;
}

/* -------------------------------------------------------------------------- */
/* Tier 2: LLM fallback                                                        */
/* -------------------------------------------------------------------------- */

/**
 * System prompt for tier 2, per the spec.
 *
 * Deliberately terse and explicit about the output contract: smaller models
 * follow "return ONLY JSON" far more reliably than prose instructions.
 */
const SMS_SYSTEM_PROMPT = `You extract structured payment data from mobile-money SMS. Return ONLY JSON matching:
{ "direction": "in"|"out", "amountMinor": integer, "currency": "BDT"|"INR", "counterparty": string|null, "reference": string|null, "confidence": 0..1 }
Rules:
- The transaction amount is NOT a fee, charge, or any balance (available/current/merchant/wallet balance).
- direction "in" for received, credited, deposited, cash in, add money, collection, payment received, merchant payment received.
- direction "out" for sent, paid, payment of ... to, cash out, recharge, bill pay, transfer ... to, debited, withdrawn.
- amountMinor is in minor units (BDT poisha / INR paisa), never a float.
- reference is the TrxID/TxnID/transaction id; if absent use Ref/Reference.
If the SMS is not a payment message, return { "error": "not_payment" }.`;

/** Confidence below this leaves the message pending instead of booking money. */
const MIN_CONFIDENCE = 0.7;

const llmSmsSchema = z.union([
	z.object({ error: z.literal("not_payment") }),
	z.object({
		direction: z.enum(["in", "out"]),
		amountMinor: z.number().int("amountMinor must be an integer").nonnegative(),
		currency: z.enum(["BDT", "INR"]).nullish(),
		counterparty: z.string().nullish(),
		reference: z.string().nullish(),
		confidence: z.number().min(0).max(1).default(0),
	}),
]);

async function parseWithLlm(
	env: Env,
	sender: string,
	body: string,
	provider: SmsProvider,
): Promise<ParseOutcome> {
	const base = inferCurrency(body, provider === "unknown" ? null : PROVIDER_CURRENCY[provider]);

	let raw: unknown;
	try {
		raw = await aiCompleteJson(env, {
			system: SMS_SYSTEM_PROMPT,
			user: `Sender: ${sender}\nSMS: ${body}`,
			json: true,
			maxTokens: 1024,
		});
	} catch (error) {
		// No provider configured, or all providers failed. `pending` is the
		// honest status: the message may well be parseable later, and
		// POST /api/sms/:id/reparse exists exactly for that retry.
		const message = error instanceof Error ? error.message : "unknown error";
		return {
			provider,
			currency: base,
			extract: null,
			parseSource: null,
			parseStatus: "pending",
			parseError: `ai_unavailable: ${message}`,
		};
	}

	const parsed = llmSmsSchema.safeParse(raw);

	if (!parsed.success) {
		return {
			provider,
			currency: base,
			extract: null,
			parseSource: "llm",
			parseStatus: "failed",
			parseError: "Model returned an unexpected shape",
			detail: parsed.error.issues.map((issue) => issue.message).join("; "),
		};
	}

	if ("error" in parsed.data) {
		return {
			provider,
			currency: base,
			extract: null,
			parseSource: "llm",
			parseStatus: "failed",
			parseError: "not_payment",
		};
	}

	const result = parsed.data;
	const currency = result.currency ?? base;
	const confidence = result.confidence;

	const extract: SmsExtract = {
		direction: result.direction,
		amountMinor: result.amountMinor,
		...(result.counterparty ? { counterparty: result.counterparty.slice(0, 120) } : {}),
		...(result.reference ? { reference: result.reference.slice(0, 64) } : {}),
	};

	if (confidence < MIN_CONFIDENCE) {
		// Low confidence: record what the model thought for review, but do not
		// let a guess become a booked financial fact.
		return {
			provider,
			currency,
			extract: null,
			parseSource: "llm",
			parseStatus: "pending",
			detail: `low_confidence:${confidence}`,
			confidence,
		};
	}

	return {
		provider,
		currency,
		extract,
		parseSource: "llm",
		parseStatus: "parsed",
		detail: `confidence:${confidence}`,
		confidence,
	};
}

/* -------------------------------------------------------------------------- */
/* Pipeline                                                                    */
/* -------------------------------------------------------------------------- */

/**
 * Two-tier parse: deterministic regex first, LLM only if that fails.
 *
 * Never throws for unparseable input - a junk SMS is a normal outcome, not an
 * error. Throws only if the caller passes something that is not an SMS at all.
 */
export async function parseSms(
	env: Env,
	input: { sender: string; body: string },
): Promise<ParseOutcome> {
	const sender = input.sender.trim();
	const body = input.body.trim();

	if (body.length === 0) {
		throw new AppError("VALIDATION_ERROR", "SMS body is empty");
	}
	if (body.length > 2000) {
		throw new AppError("VALIDATION_ERROR", "SMS body is too long");
	}

	const normalizedBody = normalizeDigits(body);
	const provider = detectProvider(sender, normalizedBody);

	// Tier 1.
	const regexResult = parseWithRegex(sender, body);
	if (regexResult) {
		const providerHint =
			regexResult.provider === "unknown" ? null : PROVIDER_CURRENCY[regexResult.provider];
		return {
			provider: regexResult.provider,
			currency: inferCurrency(normalizedBody, providerHint),
			extract: regexResult.extract,
			parseSource: "regex",
			parseStatus: "parsed",
			detail: regexResult.patternName,
			confidence: 1,
		};
	}

	// Also try the LLM when the sender is totally unknown *and* the body shows no
	// sign of being a payment message, so obviously-personal SMS short-circuit
	// to `failed` instead of burning an API call.
	if (provider === "unknown" && !looksLikePayment(normalizedBody)) {
		return {
			provider: "unknown",
			currency: null,
			extract: null,
			parseSource: null,
			parseStatus: "failed",
			parseError: "not_payment",
		};
	}

	// Tier 2.
	return parseWithLlm(env, sender, normalizedBody, provider);
}

/** Cheap pre-filter that keeps non-payment SMS away from the LLM. */
function looksLikePayment(text: string): boolean {
	return /\b(tk|bdt|taka|inr|rs\.?|₹|৳|credited|debited|received|sent|paid|payment|collection|merchant|cash\s*(in|out)|recharge|bill\s*pay|add\s*money|balance|trxid|txnid|trx\s*id|ref|bkash|nagad|rocket|dbbl|upay|ucb|upi)\b|[\d,]+\.\d{2}/i.test(
		text,
	);
}
