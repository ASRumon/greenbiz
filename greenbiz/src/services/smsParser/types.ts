/** Direction of money relative to the shop. */
export type PaymentDirection = "in" | "out";

/** Mobile money networks recognised by the parser. */
export type SmsProvider = "bkash" | "nagad" | "rocket" | "upay" | "upi" | "unknown";

/** Currency inference result. `null` means "could not tell from the message". */
export type SupportedCurrency = "BDT" | "INR";

/** Fields a tier-1 regex pattern is expected to pull out of an SMS. */
export interface SmsExtract {
	direction: PaymentDirection;
	/** Integer minor units (poisha / paisa). Never a float. */
	amountMinor: number;
	counterparty?: string;
	/** Mobile money transaction id, e.g. a bKash TrxID. */
	reference?: string;
}

/**
 * A tier-1 regex pattern.
 *
 * `regex` must capture, in order:
 *   group 1 -> amount (raw text, e.g. "1,500.00")
 *   group 2 -> counterparty (optional, may be undefined)
 *   group 3 -> reference / TrxID (optional, may be undefined)
 *
 * `extract` converts those captures into typed fields and applies the
 * direction, which is a property of the message template rather than of the
 * captured text.
 */
export interface SmsPattern {
	name: string;
	regex: RegExp;
	extract: (match: RegExpMatchArray, pattern: { direction: PaymentDirection }) => SmsExtract;
}

/** A tier-1 pattern plus the direction its template implies. */
export interface DirectedSmsPattern {
	name: string;
	regex: RegExp;
	direction: PaymentDirection;
	extract: (match: RegExpMatchArray, pattern: { direction: PaymentDirection }) => SmsExtract;
}

/** Result of running the full two-tier parse pipeline on one SMS. */
export interface ParseOutcome {
	provider: SmsProvider;
	currency: SupportedCurrency | null;
	extract: SmsExtract | null;
	/** Which tier produced `extract`. `null` when nothing parsed. */
	parseSource: "regex" | "llm" | null;
	parseStatus: "parsed" | "pending" | "failed";
	/** Populated only when `parseStatus` is `failed`. */
	parseError?: string;
	/** Pattern name for regex hits, or model confidence for LLM hits. */
	detail?: string;
	confidence?: number;
}
