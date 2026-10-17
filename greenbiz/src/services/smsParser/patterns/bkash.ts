import { makeExtractor } from "./shared";
import type { DirectedSmsPattern } from "../types";

/**
 * bKash (Bangladesh) message templates.
 *
 * Sender id is normally `16247` or `bKash`. Amounts are written as
 * `Tk 1,500.00`, and the transaction id appears as `TrxID DJG73D7KLD`.
 */

const extract = makeExtractor();

/**
 * Trailing optional segment that picks up `TrxID XXXXXXXX`.
 *
 * The `.*?` is lazy so the engine finds the *first* TrxID in the message; the
 * whole group is optional so templates without an id still match.
 */
const TRX = String.raw`(?:.*?\btrxid[:\s]*([a-z0-9]{6,24}))?`;

/** `Tk 1,500.00` / `Tk.1500` / `BDT 1,500.00` -> capture the number only. */
const AMOUNT = String.raw`(?:tk\.?|bdt|taka)?\s*([\d,]+(?:\.\d{1,2})?)`;

export const bkashPatterns: DirectedSmsPattern[] = [
	{
		// "You have received Tk 1,500.00 from 01782665484. Fee Tk 0.00. Balance Tk 1,699.05. TrxID DJG73D7KLD at 16/10/2026 15:46"
		name: "bkash.received",
		direction: "in",
		regex: new RegExp(
			String.raw`you\s+have\s+received\s+${AMOUNT}\s+from\s+([^\s.]+)` + TRX,
			"is",
		),
		extract,
	},
	{
		// "You have sent Tk 500.00 to 01712345678. Fee Tk 0.00. Balance Tk 1,199.05. TrxID ABC123XYZ at ..."
		name: "bkash.sent",
		direction: "out",
		regex: new RegExp(String.raw`you\s+have\s+sent\s+${AMOUNT}\s+to\s+([^\s.]+)` + TRX, "is"),
		extract,
	},
	{
		// "Payment of Tk 200.00 to MERCHANT NAME successful. TrxID P1A2Y3X4Z5 at 16/10/2026"
		name: "bkash.payment",
		direction: "out",
		regex: new RegExp(String.raw`payment\s+of\s+${AMOUNT}\s+to\s+([^.]{1,60}?)\s*\.?\s*successful` + TRX, "is"),
		extract,
	},
	{
		// "Cash In Tk 2,000.00 from 01712345678 successful. TrxID ..." (money into the wallet)
		name: "bkash.cash_in",
		direction: "in",
		regex: new RegExp(String.raw`cash\s+in\s+${AMOUNT}\s+from\s+([^\s.]+)` + TRX, "is"),
		extract,
	},
	{
		// "Cash Out Tk 1,000.00 to 01712345678 successful. TrxID ..."
		name: "bkash.cash_out",
		direction: "out",
		regex: new RegExp(String.raw`cash\s+out\s+${AMOUNT}\s+to\s+([^\s.]+)` + TRX, "is"),
		extract,
	},
];

/**
 * Bangla-language bKash templates.
 *
 * Example: "আপনি ১,৫০০.০০ টাকা পেয়েছেন ০১৭৮২৬৬৫৪৮৪ থেকে। TrxID DJG73D7KLD"
 * Run on text that has already been through `normalizeDigits`, so `[\d,]+`
 * works unchanged.
 */
export const bkashBanglaPatterns: DirectedSmsPattern[] = [
	{
		name: "bkash.bn.received",
		direction: "in",
		regex: new RegExp(String.raw`([\d,]+(?:\.\d{1,2})?)\s*টাকা\s*পেয়েছেন\s*([^\s।]+)` + TRX, "is"),
		extract,
	},
	{
		name: "bkash.bn.sent",
		direction: "out",
		regex: new RegExp(String.raw`([\d,]+(?:\.\d{1,2})?)\s*টাকা\s*(?:পাঠিয়েছেন|সেন্ড)` + TRX, "is"),
		extract,
	},
];
