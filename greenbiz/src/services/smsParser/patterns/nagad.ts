import { makeExtractor } from "./shared";
import type { DirectedSmsPattern } from "../types";

/**
 * Nagad (Bangladesh Post) message templates.
 *
 * Sender ids are typically `16248` / `Nagad`. Wording varies more than bKash:
 * both "You have received" and "Amount received" styles are in the wild, and
 * the reference is written as `TrxID:` or `TxnID`.
 */

const extract = makeExtractor();

const REF = String.raw`(?:.*?\b(?:trx|txn|transaction)\s*id[:\s#]*([a-z0-9]{6,24}))?`;
const AMOUNT = String.raw`(?:tk\.?|bdt|taka)?\s*([\d,]+(?:\.\d{1,2})?)`;

export const nagadPatterns: DirectedSmsPattern[] = [
	{
		// "You have received Tk 500.00 from 01712345678. Your new balance is Tk 1,500.00. TrxID: 1234567890"
		name: "nagad.received",
		direction: "in",
		regex: new RegExp(
			String.raw`you\s+have\s+received\s+${AMOUNT}\s+from\s+([^\s.]+)` + REF,
			"is",
		),
		extract,
	},
	{
		// "You have sent Tk 200.00 to 01712345678. ... TxnID: 1234567890"
		name: "nagad.sent",
		direction: "out",
		regex: new RegExp(String.raw`you\s+have\s+sent\s+${AMOUNT}\s+to\s+([^\s.]+)` + REF, "is"),
		extract,
	},
	{
		// "Nagad: Cash In successful. Amount: Tk 1000.00 from 01712345678. TrxID: 1234567890"
		name: "nagad.cash_in",
		direction: "in",
		regex: new RegExp(
			String.raw`cash\s*in\s*(?:successful)?\.?\s*amount[:\s]*${AMOUNT}\s*from\s*([^\s.]+)` + REF,
			"is",
		),
		extract,
	},
	{
		// "Nagad: Cash Out successful. Amount: Tk 500.00 to 01712345678. TrxID: ..."
		name: "nagad.cash_out",
		direction: "out",
		regex: new RegExp(
			String.raw`cash\s*out\s*(?:successful)?\.?\s*amount[:\s]*${AMOUNT}\s*to\s*([^\s.]+)` + REF,
			"is",
		),
		extract,
	},
	{
		// "Payment successful. You have paid Tk 350.00 to MERCHANT. TrxID: ..."
		name: "nagad.payment",
		direction: "out",
		regex: new RegExp(String.raw`you\s+have\s+paid\s+${AMOUNT}\s+to\s+([^.]{1,60}?)\s*\.` + REF, "is"),
		extract,
	},
];
