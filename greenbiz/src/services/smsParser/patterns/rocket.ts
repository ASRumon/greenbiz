import { makeExtractor } from "./shared";
import type { DirectedSmsPattern } from "../types";

/**
 * Rocket (DBBL Mobile Banking, Bangladesh) message templates.
 *
 * Sender id is usually `16216` / `Rocket`. Rocket references are 12-digit
 * numbers and are labelled `TxnID` or `Reference` / `Ref`.
 */

const extract = makeExtractor();

const REF = String.raw`(?:.*?\b(?:txn\s*id|trx\s*id|reference|ref|trxid)[:\s#]*([a-z0-9]{6,24}))?`;
const AMOUNT = String.raw`(?:tk\.?|bdt|taka)?\s*([\d,]+(?:\.\d{1,2})?)`;

export const rocketPatterns: DirectedSmsPattern[] = [
	{
		// "You have received Tk 1,000.00 from 01712345678. Reference: 123456789012. Your new balance: Tk 2,000.00"
		name: "rocket.received",
		direction: "in",
		regex: new RegExp(
			String.raw`(?:you\s+have\s+)?received\s+${AMOUNT}\s+from\s+([^\s.]+)` + REF,
			"is",
		),
		extract,
	},
	{
		// "You have sent Tk 500.00 to 01712345678. ... TxnID 123456789012"
		name: "rocket.sent",
		direction: "out",
		regex: new RegExp(String.raw`(?:you\s+have\s+)?sent\s+${AMOUNT}\s+to\s+([^\s.]+)` + REF, "is"),
		extract,
	},
	{
		// "Rocket: Money received Tk 750.00 from 01712345678 ..."
		name: "rocket.money_received",
		direction: "in",
		regex: new RegExp(String.raw`money\s+received\s+${AMOUNT}\s+from\s+([^\s.]+)` + REF, "is"),
		extract,
	},
	{
		// "Rocket: Money sent Tk 250.00 to 01712345678 ..."
		name: "rocket.money_sent",
		direction: "out",
		regex: new RegExp(String.raw`money\s+sent\s+${AMOUNT}\s+to\s+([^\s.]+)` + REF, "is"),
		extract,
	},
	{
		// "Cash Out Tk 2,000.00 from your Rocket account ... TxnID ..."
		name: "rocket.cash_out",
		direction: "out",
		regex: new RegExp(String.raw`cash\s+out\s+${AMOUNT}` + REF, "is"),
		extract,
	},
];
