import { makeExtractor } from "./shared";
import type { DirectedSmsPattern } from "../types";

/**
 * UPI / Indian bank payment alert templates.
 *
 * UPI alerts arrive from bank sender ids (e.g. `VM-HDFCBK`, `AD-SBIINB`) or
 * from the PSP, and write amounts as `Rs.500`, `INR 500`, or `Rs 500.00`.
 * References are labelled `UPI Ref`, `Ref No`, `UTR`, or `RRN`.
 */

const extract = makeExtractor();

const REF = String.raw`(?:.*?\b(?:upi\s*(?:ref|txn)|ref\s*no|ref|utr|rrn)[:.\s#]*([a-z0-9]{6,24}))?`;
const AMOUNT = String.raw`(?:inr|rs\.?|₹)\s*\.?\s*([\d,]+(?:\.\d{1,2})?)`;

export const upiPatterns: DirectedSmsPattern[] = [
	{
		// "Rs.500.00 credited to your A/c XXXX1234 on 16-10-2026. UPI Ref 123456789012"
		name: "upi.credited",
		direction: "in",
		regex: new RegExp(
			String.raw`${AMOUNT}\s*(?:has\s+been\s+)?credited(?:\s+to\s+(?:your\s+)?(?:a\/c|account)\s*([^\s,.]{1,24}))?` +
				REF,
			"is",
		),
		extract,
	},
	{
		// "Rs.200.00 debited from your A/c XXXX1234. UPI Ref 123456789012"
		name: "upi.debited",
		direction: "out",
		regex: new RegExp(
			String.raw`${AMOUNT}\s*(?:has\s+been\s+)?debited(?:\s+from\s+(?:your\s+)?(?:a\/c|account)\s*([^\s,.]{1,24}))?` +
				REF,
			"is",
		),
		extract,
	},
	{
		// "You have received Rs.1,500.00 from RAHUL SHARMA. UPI Ref 123456789012"
		name: "upi.received_from",
		direction: "in",
		regex: new RegExp(
			String.raw`you\s+have\s+received\s+${AMOUNT}\s+from\s+([^.]{1,40}?)\s*\.` + REF,
			"is",
		),
		extract,
	},
	{
		// "Sent Rs.500.00 to RAHUL SHARMA. UPI Ref ..."
		name: "upi.sent_to",
		direction: "out",
		regex: new RegExp(String.raw`sent\s+${AMOUNT}\s+to\s+([^.]{1,40}?)\s*\.` + REF, "is"),
		extract,
	},
	{
		// "Your A/c XX1234 has been credited with Rs.2,000.00 ... UTR 123456789012"
		name: "upi.credited_with",
		direction: "in",
		regex: new RegExp(
			String.raw`credited\s+with\s+${AMOUNT}[^.]*?(?:a\/c|account)?\s*([^\s,.]{1,24})?` + REF,
			"is",
		),
		extract,
	},
	{
		// "Paid Rs.150.00 to MERCHANT via UPI. UPI Ref ..."
		name: "upi.paid_to",
		direction: "out",
		regex: new RegExp(String.raw`paid\s+${AMOUNT}\s+to\s+([^.]{1,40}?)(?:\s+via)?\s*\.` + REF, "is"),
		extract,
	},
];
