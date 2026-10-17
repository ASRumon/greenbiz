import { describe, expect, it } from "vitest";
import {
	detectProvider,
	parseAmountMinor,
	parseWithRegex,
} from "../src/services/smsParser";
import { normalizeDigits } from "../src/services/smsParser/patterns/shared";

/**
 * Tier-1 parser tests.
 *
 * These are the highest-value tests in the Worker: a regex that silently stops
 * matching is not a crash, it is a silent loss of the shop's revenue history.
 * Every template below is a realistic message body.
 */

describe("parseAmountMinor", () => {
	it("converts major units to minor units exactly", () => {
		expect(parseAmountMinor("1500")).toBe(150000);
		expect(parseAmountMinor("1,500.00")).toBe(150000);
		expect(parseAmountMinor("1699.05")).toBe(169905);
		expect(parseAmountMinor("1,699.05")).toBe(169905);
		expect(parseAmountMinor("0.01")).toBe(1);
		expect(parseAmountMinor("0.5")).toBe(50);
		expect(parseAmountMinor("1,00,000.50")).toBe(10000050);
	});

	it("avoids binary floating-point drift", () => {
		// parseFloat("1699.05") * 100 === 169905.00000000003
		expect(parseAmountMinor("1699.05")).toBe(169905);
		expect(parseAmountMinor("1234567.89")).toBe(123456789);
		expect(parseAmountMinor("0.07")).toBe(7);
	});

	it("rejects values that cannot be represented in minor units", () => {
		// A third decimal place has no paisa equivalent, so it is an error and
		// not a silent truncation.
		expect(parseAmountMinor("1.005")).toBeNaN();
		expect(parseAmountMinor("abc")).toBeNaN();
		expect(parseAmountMinor("")).toBeNaN();
		expect(parseAmountMinor("1e5")).toBeNaN();
	});
});

describe("normalizeDigits", () => {
	it("converts Bengali and Devanagari numerals to ASCII", () => {
		expect(normalizeDigits("১,৫০০.০০")).toBe("1,500.00");
		expect(normalizeDigits("१५००")).toBe("1500");
	});

	it("leaves ASCII text untouched", () => {
		expect(normalizeDigits("Tk 1,500.00")).toBe("Tk 1,500.00");
	});
});

describe("detectProvider", () => {
	it("recognises Bangladeshi short codes", () => {
		expect(detectProvider("16247", "anything")).toBe("bkash");
		expect(detectProvider("16248", "anything")).toBe("nagad");
		expect(detectProvider("16216", "anything")).toBe("rocket");
		expect(detectProvider("bKash", "anything")).toBe("bkash");
	});

	it("recognises Indian bank headers with prefixes", () => {
		expect(detectProvider("VM-HDFCBK", "anything")).toBe("upi");
		expect(detectProvider("AD-SBIINB", "anything")).toBe("upi");
	});

	it("falls back to body keywords", () => {
		expect(detectProvider("Unknown", "Your bKash account has been debited")).toBe("bkash");
		expect(detectProvider("Unknown", "Nagad: cash in successful")).toBe("nagad");
	});

	it("returns unknown when there is no evidence", () => {
		expect(detectProvider("01712345678", "Hi, are we meeting today?")).toBe("unknown");
	});
});

describe("parseWithRegex — bKash", () => {
	it("parses the canonical received-money template", () => {
		const result = parseWithRegex(
			"16247",
			"You have received Tk 1,500.00 from 01782665484. Fee Tk 0.00. Balance Tk 1,699.05. TrxID DJG73D7KLD at 16/10/2026 15:46",
		);

		expect(result).not.toBeNull();
		expect(result!.provider).toBe("bkash");
		expect(result!.extract.direction).toBe("in");
		expect(result!.extract.amountMinor).toBe(150000);
		expect(result!.extract.counterparty).toBe("01782665484");
		expect(result!.extract.reference).toBe("DJG73D7KLD");
	});

	it("parses sent money as an outflow", () => {
		const result = parseWithRegex(
			"16247",
			"You have sent Tk 500.00 to 01712345678. Fee Tk 0.00. Balance Tk 1,199.05. TrxID ABC123XYZ at 16/10/2026 16:10",
		);

		expect(result?.extract.direction).toBe("out");
		expect(result?.extract.amountMinor).toBe(50000);
		expect(result?.extract.reference).toBe("ABC123XYZ");
	});

	it("still parses when the TrxID is absent", () => {
		const result = parseWithRegex(
			"bKash",
			"You have received Tk 250.00 from 01711111111. Balance Tk 900.00.",
		);

		expect(result?.extract.amountMinor).toBe(25000);
		expect(result?.extract.reference).toBeUndefined();
	});

	it("parses cash in and cash out", () => {
		const cashIn = parseWithRegex(
			"16247",
			"Cash In Tk 2,000.00 from 01712345678 successful. TrxID CASHIN1234",
		);
		expect(cashIn?.extract.direction).toBe("in");
		expect(cashIn?.extract.amountMinor).toBe(200000);

		const cashOut = parseWithRegex(
			"16247",
			"Cash Out Tk 1,000.00 to 01712345678 successful. TrxID CASHOUT123",
		);
		expect(cashOut?.extract.direction).toBe("out");
		expect(cashOut?.extract.amountMinor).toBe(100000);
	});

	it("parses a Bangla-language message after digit normalisation", () => {
		const result = parseWithRegex(
			"16247",
			"আপনি ১,৫০০.০০ টাকা পেয়েছেন ০১৭৮২৬৬৫৪৮৪ থেকে। TrxID DJG73D7KLD",
		);

		expect(result?.extract.direction).toBe("in");
		expect(result?.extract.amountMinor).toBe(150000);
	});
});

describe("parseWithRegex — other networks", () => {
	it("parses Nagad with a colon-style reference", () => {
		const result = parseWithRegex(
			"16248",
			"You have received Tk 850.00 from 01722334455. Your new balance is Tk 2,049.05. TrxID: 9988776655",
		);

		expect(result?.provider).toBe("nagad");
		expect(result?.extract.amountMinor).toBe(85000);
		expect(result?.extract.reference).toBe("9988776655");
	});

	it("parses Rocket with a Reference label", () => {
		const result = parseWithRegex(
			"16216",
			"You have received Tk 1,000.00 from 01733445566. Reference: 123456789012. Your new balance: Tk 3,049.05",
		);

		expect(result?.provider).toBe("rocket");
		expect(result?.extract.amountMinor).toBe(100000);
		expect(result?.extract.reference).toBe("123456789012");
	});

	it("parses a UPI credit alert", () => {
		const result = parseWithRegex(
			"VM-HDFCBK",
			"Rs.500.00 credited to your A/c XXXX1234 on 16-10-2026. UPI Ref 445566778899",
		);

		expect(result?.provider).toBe("upi");
		expect(result?.extract.direction).toBe("in");
		expect(result?.extract.amountMinor).toBe(50000);
		expect(result?.extract.reference).toBe("445566778899");
	});

	it("parses a UPI debit alert", () => {
		const result = parseWithRegex(
			"AD-SBIINB",
			"Rs.200.00 debited from your A/c XXXX1234. UPI Ref 998877665544",
		);

		expect(result?.extract.direction).toBe("out");
		expect(result?.extract.amountMinor).toBe(20000);
	});
});

describe("structural parser — all provider layouts", () => {
	const cases: Array<{
		name: string;
		sender: string;
		body: string;
		provider: string;
		direction: "in" | "out";
		amountMinor: number;
		reference?: string;
	}> = [
		{
			name: "bKash cash-in from agent",
			sender: "bKash",
			body:
				"You have received Tk 5,000.00 from Agent 0171X-XXXXXX. TrxID 8G72ABC1DE at 17/10/2026 14:30. Balance Tk 5,750.00.",
			provider: "bkash",
			direction: "in",
			amountMinor: 500000,
			reference: "8G72ABC1DE",
		},
		{
			name: "bKash mobile top-up",
			sender: "bKash",
			body:
				"Mobile Recharge Tk 200.00 to 019XXXXXXXX successful. TrxID 8G73KLM4NP at 17/10/2026 16:15. Fee Tk 0.00. Balance Tk 550.00.",
			provider: "bkash",
			direction: "out",
			amountMinor: 20000,
			reference: "8G73KLM4NP",
		},
		{
			name: "bKash merchant payment",
			sender: "bKash",
			body:
				"Payment Tk 1,200.00 to Aarong successful. TrxID 8G74XYZ7QR at 17/10/2026 20:10. Reference: Bill01. Balance Tk 3,450.00.",
			provider: "bkash",
			direction: "out",
			amountMinor: 120000,
			reference: "8G74XYZ7QR",
		},
		{
			name: "bKash utility bill",
			sender: "bKash",
			body:
				"Bill Pay successful. Organization: DESCO Postpaid. Account No: 100234567. Amount: Tk 2,450.00. Fee: Tk 5.00. TrxID 8G75QWE2RT at 17/10/2026 11:05. Balance Tk 1,200.00.",
			provider: "bkash",
			direction: "out",
			amountMinor: 245000,
			reference: "8G75QWE2RT",
		},
		{
			name: "bKash bank to wallet",
			sender: "bKash",
			body:
				"Tk 10,000.00 added to your Account from BRAC Bank Account/Card. TrxID 8G76VBN3MK at 17/10/2026 09:12. Balance Tk 12,300.00.",
			provider: "bkash",
			direction: "in",
			amountMinor: 1000000,
			reference: "8G76VBN3MK",
		},
		{
			name: "Nagad cash-in",
			sender: "Nagad",
			body:
				"Cash In of Tk 3,000.00 is successful. Agent: 0182X-XXXXXX. TrxID: NGD88776655. Fee: Tk 0.00. Balance: Tk 4,500.00. Date: 17/10/2026 12:40.",
			provider: "nagad",
			direction: "in",
			amountMinor: 300000,
			reference: "NGD88776655",
		},
		{
			name: "Nagad mobile top-up",
			sender: "Nagad",
			body:
				"Mobile Recharge of Tk 50.00 to 015XXXXXXXX is successful. TrxID: NGD44332211. Fee: Tk 0.00. Balance: Tk 450.00. Date: 17/10/2026 13:00.",
			provider: "nagad",
			direction: "out",
			amountMinor: 5000,
			reference: "NGD44332211",
		},
		{
			name: "Nagad merchant payment",
			sender: "Nagad",
			body:
				"Payment of Tk 850.00 to Shwapno is successful. TrxID: NGD11223344. Fee: Tk 0.00. Balance: Tk 1,200.00. Date: 17/10/2026 21:15.",
			provider: "nagad",
			direction: "out",
			amountMinor: 85000,
			reference: "NGD11223344",
		},
		{
			name: "Nagad utility bill",
			sender: "Nagad",
			body:
				"Bill Pay of Tk 1,800.00 to DPDC is successful. Consumer No: 9876543. TrxID: NGD55667788. Fee: Tk 10.00. Balance: Tk 2,100.00.",
			provider: "nagad",
			direction: "out",
			amountMinor: 180000,
			reference: "NGD55667788",
		},
		{
			name: "Nagad add money",
			sender: "Nagad",
			body:
				"Add Money of Tk 5,000.00 from Sonali Bank is successful. TrxID: NGD99001122. Fee: Tk 0.00. Balance: Tk 6,400.00.",
			provider: "nagad",
			direction: "in",
			amountMinor: 500000,
			reference: "NGD99001122",
		},
		{
			name: "Rocket cash-in",
			sender: "Rocket",
			body:
				"Rocket: Cash-In of Tk 4,000.00 through Agent 0191X-XXXXXX is successful. TrxID: DBBL112233. Fee: Tk 0.00. Available Balance: Tk 5,200.00.",
			provider: "rocket",
			direction: "in",
			amountMinor: 400000,
			reference: "DBBL112233",
		},
		{
			name: "Rocket mobile recharge",
			sender: "Rocket",
			body:
				"Rocket: Mobile Recharge of Tk 100.00 to 017XXXXXXXX is successful. TrxID: DBBL445566. Available Balance: Tk 800.00.",
			provider: "rocket",
			direction: "out",
			amountMinor: 10000,
			reference: "DBBL445566",
		},
		{
			name: "Rocket merchant payment",
			sender: "Rocket",
			body:
				"Rocket: Merchant Pay of Tk 2,300.00 to Daraz Bangladesh is successful. TrxID: DBBL778899. Available Balance: Tk 1,500.00.",
			provider: "rocket",
			direction: "out",
			amountMinor: 230000,
			reference: "DBBL778899",
		},
		{
			name: "Rocket utility bill",
			sender: "Rocket",
			body:
				"Rocket: Bill Pay of Tk 3,200.00 to Dhaka WASA is successful. Biller ID: 320. TrxID: DBBL001122. Fee: Tk 10.00. Available Balance: Tk 900.00.",
			provider: "rocket",
			direction: "out",
			amountMinor: 320000,
			reference: "DBBL001122",
		},
		{
			name: "Rocket transfer to bank",
			sender: "Rocket",
			body:
				"Rocket: Transfer of Tk 7,000.00 to DBBL A/C 123.XXX.XXXXX is successful. TrxID: DBBL334455. Fee: Tk 70.00. Available Balance: Tk 1,100.00.",
			provider: "rocket",
			direction: "out",
			amountMinor: 700000,
			reference: "DBBL334455",
		},
		{
			name: "Upay cash-in",
			sender: "upay",
			body:
				"upay: Cash In Tk 2,000.00 from Agent 0161X-XXXXXX successful. TrxID: UPY776655. Fee: Tk 0.00. Current Balance: Tk 2,850.00. 17/10/2026 15:45.",
			provider: "upay",
			direction: "in",
			amountMinor: 200000,
			reference: "UPY776655",
		},
		{
			name: "Upay send money",
			sender: "upay",
			body:
				"upay: Sent Money Tk 1,500.00 to 018XXXXXXXX successful. TrxID: UPY443322. Fee: Tk 0.00. Current Balance: Tk 1,350.00.",
			provider: "upay",
			direction: "out",
			amountMinor: 150000,
			reference: "UPY443322",
		},
		{
			name: "Upay cash-out",
			sender: "upay",
			body:
				"upay: Cash Out Tk 1,000.00 from Agent successful. TrxID: UPY112233. Fee: Tk 14.00. Current Balance: Tk 336.00.",
			provider: "upay",
			direction: "out",
			amountMinor: 100000,
			reference: "UPY112233",
		},
		{
			name: "Upay utility bill",
			sender: "upay",
			body:
				"upay: Bill Pay Tk 950.00 to Titas Gas successful. TrxID: UPY998877. Fee: Tk 5.00. Current Balance: Tk 45.00.",
			provider: "upay",
			direction: "out",
			amountMinor: 95000,
			reference: "UPY998877",
		},
		{
			name: "bKash merchant receipt",
			sender: "bKash",
			body:
				"You have received payment of Tk 1,200.00 from 017XXXXXXXX. Ref: Bill01. Counter: 1. TrxID 8G74XYZ7QR at 17/10/2026 20:10. Balance Tk 145,200.00.",
			provider: "bkash",
			direction: "in",
			amountMinor: 120000,
			reference: "8G74XYZ7QR",
		},
		{
			name: "Nagad merchant receipt",
			sender: "Nagad",
			body:
				"Merchant Pay Received of Tk 850.00 from Customer 019XXXXXXXX. TrxID: NGD11223344. Store ID: 02. Date: 17/10/2026 21:15. Total Wallet Balance: Tk 89,450.00.",
			provider: "nagad",
			direction: "in",
			amountMinor: 85000,
			reference: "NGD11223344",
		},
		{
			name: "Rocket merchant receipt",
			sender: "Rocket",
			body:
				"Rocket: Merchant Payment Received of Tk 2,300.00 from 015XXXXXXXX. TrxID: DBBL778899. Available Merchant Balance: Tk 312,800.00.",
			provider: "rocket",
			direction: "in",
			amountMinor: 230000,
			reference: "DBBL778899",
		},
		{
			name: "Upay merchant collection",
			sender: "upay",
			body:
				"upay: Collection of Tk 950.00 from 016XXXXXXXX successful. TrxID: UPY998877. Current Merchant Balance: Tk 42,150.00.",
			provider: "upay",
			direction: "in",
			amountMinor: 95000,
			reference: "UPY998877",
		},
	];

	it.each(cases)("$name", ({ sender, body, provider, direction, amountMinor, reference }) => {
		const result = parseWithRegex(sender, body);

		expect(result).not.toBeNull();
		expect(result!.provider).toBe(provider);
		expect(result!.extract.direction).toBe(direction);
		expect(result!.extract.amountMinor).toBe(amountMinor);
		if (reference) expect(result!.extract.reference).toBe(reference);
	});

	it("recognises the current and legacy shortcodes", () => {
		expect(detectProvider("16167", "anything")).toBe("nagad");
		expect(detectProvider("16248", "anything")).toBe("nagad");
		expect(detectProvider("16222", "anything")).toBe("rocket");
		expect(detectProvider("16268", "anything")).toBe("upay");
	});
});

describe("structural parser — wording changes", () => {
	const futureCases: Array<{
		name: string;
		sender: string;
		body: string;
		direction: "in" | "out";
		amountMinor: number;
	}> = [
		{
			name: "a new credit wording with a brand in the body",
			sender: "64444",
			body:
				"Payment credited: Tk 1,234.00 from 017XXXXXXXX via bKash. Txn ID ABC12345. Balance Tk 9,000.00.",
			direction: "in",
			amountMinor: 123400,
		},
		{
			name: "merchant collection with different nouns",
			sender: "Nagad",
			body:
				"Merchant collection of Tk 900.00 received from Customer 018XXXXXXXX. Transaction ID XYZ98765.",
			direction: "in",
			amountMinor: 90000,
		},
		{
			name: "transfer wording changes from Transfer to Transferred",
			sender: "Rocket",
			body:
				"Rocket: Transferred Tk 2,000.00 to 019XXXXXXXX successfully. TrxID DBBL556677.",
			direction: "out",
			amountMinor: 200000,
		},
		{
			name: "bill payment with Amount label",
			sender: "upay",
			body:
				"upay: Bill payment completed. Amount: Tk 300.00. Fee: Tk 2.00. TrxID UPY102030.",
			direction: "out",
			amountMinor: 30000,
		},
		{
			name: "account debit wording",
			sender: "bKash",
			body:
				"Your account was debited by Tk 500.00 for a purchase. TrxID 8G99DEBITX.",
			direction: "out",
			amountMinor: 50000,
		},
		{
			name: "money received with a new sentence",
			sender: "16247",
			body:
				"You have received money. Tk 2,500.00 from 017XXXXXXXX. TrxID 8G88CREDIT.",
			direction: "in",
			amountMinor: 250000,
		},
	];

	it.each(futureCases)("$name", ({ sender, body, direction, amountMinor }) => {
		const result = parseWithRegex(sender, body);

		expect(result).not.toBeNull();
		expect(result!.extract.direction).toBe(direction);
		expect(result!.extract.amountMinor).toBe(amountMinor);
	});
});

describe("parseWithRegex — negative cases", () => {
	it("returns null for a personal message", () => {
		expect(
			parseWithRegex("PERSONAL", "Hey, are we still meeting for tea at 5pm today?"),
		).toBeNull();
	});

	it("returns null for an OTP message", () => {
		expect(
			parseWithRegex("16247", "Your verification code is 123456. Do not share it with anyone."),
		).toBeNull();
	});

	it("returns null for a promotional message that mentions a balance", () => {
		expect(
			parseWithRegex(
				"16247",
				"Enjoy 10% cashback! Check your balance in the app to see your offers.",
			),
		).toBeNull();
	});

	it("is not confused by an amount with three decimal places", () => {
		// Structurally the message matches, but the amount is unusable. The
		// parser must fall through rather than book a rounded value.
		const result = parseWithRegex("16247", "You have received Tk 1.005 from 01712345678.");
		expect(result).toBeNull();
	});
});

describe("regex state is not shared between calls", () => {
	it("parses the same message repeatedly with identical results", () => {
		const body =
			"You have received Tk 1,500.00 from 01782665484. Fee Tk 0.00. Balance Tk 1,699.05. TrxID DJG73D7KLD at 16/10/2026 15:46";

		// A `g`-flagged RegExp would advance lastIndex and fail on the second
		// call. This asserts the patterns stay reusable across a bulk import.
		for (let attempt = 0; attempt < 5; attempt += 1) {
			const result = parseWithRegex("16247", body);
			expect(result?.extract.amountMinor).toBe(150000);
			expect(result?.extract.reference).toBe("DJG73D7KLD");
		}
	});
});
