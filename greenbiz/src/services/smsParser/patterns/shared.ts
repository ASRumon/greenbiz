import type { SmsExtract, SupportedCurrency } from "../types";

/**
 * Amount parsing that never touches a float.
 *
 * `parseFloat("1699.05") * 100` is 169905.00000000003 in IEEE-754. Rounding
 * hides that here, but the same mistake compounding across a ledger does not
 * stay hidden. Splitting the integer and fractional parts as *strings* makes
 * the conversion exact by construction.
 *
 * Returns `NaN` when the text is not a well-formed amount, which the caller
 * treats as "pattern did not match".
 */
export function parseAmountMinor(raw: string): number {
	// Tolerate thousands separators and whitespace inside the number.
	const cleaned = raw.replace(/[,\s]/g, "");

	// Allow "1500", "1500.5", "1500.05". Reject 3+ decimal places rather than
	// silently truncating: a value like 1.005 is not representable in paisa.
	const match = /^(\d+)(?:\.(\d{1,2}))?$/.exec(cleaned);
	if (!match) return Number.NaN;

	const wholePart = match[1];
	const fractionPart = (match[2] ?? "").padEnd(2, "0");

	const whole = Number(wholePart);
	if (!Number.isSafeInteger(whole)) return Number.NaN;

	return whole * 100 + Number(fractionPart);
}

/** Trims an optional capture down to a usable value, or undefined. */
export function cleanOptional(value: string | undefined): string | undefined {
	if (value === undefined) return undefined;
	const trimmed = value.trim().replace(/[.,;:]+$/, "");
	return trimmed.length === 0 ? undefined : trimmed;
}

/**
 * Builds the `extract` function used by every pattern.
 *
 * Keeping this in one place means each pattern file only has to describe its
 * regex and direction; the capture-to-field mapping cannot drift between them.
 */
export function makeExtractor() {
	return (match: RegExpMatchArray, pattern: { direction: "in" | "out" }): SmsExtract => {
		const amountMinor = parseAmountMinor(match[1] ?? "");
		if (!Number.isFinite(amountMinor)) {
			// Signals "regex matched structurally but the amount was unusable".
			throw new Error(`Unparseable amount: ${JSON.stringify(match[1])}`);
		}

		const counterparty = cleanOptional(match[2]);
		const reference = cleanOptional(match[3]);

		return {
			direction: pattern.direction,
			amountMinor,
			...(counterparty === undefined ? {} : { counterparty }),
			...(reference === undefined ? {} : { reference }),
		};
	};
}

/**
 * Converts Bengali digits to ASCII so patterns written against ASCII numerals
 * also match Bangla SMS. Nagad and some bank alerts send numerals in Bangla.
 */
export function normalizeDigits(input: string): string {
	const BENGALI_ZERO = 0x09e6;
	const DEVANAGARI_ZERO = 0x0966;

	return input.replace(/[\u09e6-\u09ef\u0966-\u096f]/g, (char) => {
		const codePoint = char.codePointAt(0);
		if (codePoint === undefined) return char;
		if (codePoint >= BENGALI_ZERO && codePoint <= BENGALI_ZERO + 9) {
			return String(codePoint - BENGALI_ZERO);
		}
		if (codePoint >= DEVANAGARI_ZERO && codePoint <= DEVANAGARI_ZERO + 9) {
			return String(codePoint - DEVANAGARI_ZERO);
		}
		return char;
	});
}

/**
 * Guesses the currency from explicit currency words, falling back to the
 * network. Returns null when there is no evidence at all, so the caller can
 * fall back to the shop's default rather than inventing a currency.
 */
export function inferCurrency(text: string, providerHint: SupportedCurrency | null): SupportedCurrency | null {
	if (/\b(inr|rs\.?|rupees?)\b/i.test(text)) return "INR";
	if (/\b(bdt|tk\.?|taka|৳)\b/i.test(text)) return "BDT";
	return providerHint;
}
