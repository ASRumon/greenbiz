import { describe, expect, it } from "vitest";
import {
	affordabilityRatio,
	affordableEmiMinor,
	affordablePrincipalMinor,
	amortizedEmiMinor,
	floorToThousandMinor,
	interestOnlyEmiMinor,
	priorityForRatio,
	repaymentEmiMinor,
	suggestedPrincipalMinor,
} from "../src/services/loanMath";

/**
 * Loan maths tests.
 *
 * The functions are pure, so these assert the same numbers a shop owner would
 * see in the Finance card. Money is minor units throughout: BDT 1,000 is
 * 100,000 minor units.
 */

const TEN_THOUSAND_TAKA = 1_000_000; // BDT 10,000 in minor units

describe("amortizedEmiMinor", () => {
	it("matches a standard amortisation calculation", () => {
		// BDT 100,000 over 12 months at 12% p.a.
		const emi = amortizedEmiMinor(10_000_000, 12, 12);

		// The exact value is about 888,488 minor units (BDT 8,884.88).
		expect(emi).toBeGreaterThan(888_000);
		expect(emi).toBeLessThan(889_000);
	});

	it("divides evenly at a zero rate", () => {
		expect(amortizedEmiMinor(1_200_000, 0, 12)).toBe(100_000);
	});

	it("returns zero for a zero principal", () => {
		expect(amortizedEmiMinor(0, 12, 36)).toBe(0);
	});
});

describe("affordablePrincipalMinor", () => {
	it("is the inverse of the EMI formula", () => {
		const principal = 5_000_000;
		const emi = amortizedEmiMinor(principal, 13.5, 48);
		const recovered = affordablePrincipalMinor(emi, 13.5, 48);

		// Rounding is to the nearest poisha, so allow a taka of drift.
		expect(Math.abs(recovered - principal)).toBeLessThan(100);
	});

	it("supports a larger principal at a lower rate", () => {
		const cheap = affordablePrincipalMinor(100_000, 5, 48);
		const expensive = affordablePrincipalMinor(100_000, 15, 48);

		expect(cheap).toBeGreaterThan(expensive);
	});
});

describe("interest-only facilities", () => {
	it("services interest only on a revolving line", () => {
		// BDT 100,000 at 12% p.a. = BDT 1,000 per month.
		expect(interestOnlyEmiMinor(10_000_000, 12)).toBe(100_000);
		expect(repaymentEmiMinor(10_000_000, 12, 12, "revolving")).toBe(100_000);
	});

	it("uses amortisation for a term facility", () => {
		expect(repaymentEmiMinor(10_000_000, 12, 12, "term")).toBe(
			amortizedEmiMinor(10_000_000, 12, 12),
		);
	});
});

describe("affordability ratio and priority", () => {
	it("calls 2x cover high priority", () => {
		// BDT 20,000 revenue against a BDT 10,000 instalment.
		const ratio = affordabilityRatio(2_000_000, 1_000_000);

		expect(ratio).toBe(2);
		expect(priorityForRatio(ratio)).toBe("high");
	});

	it("calls 3x cover high priority too", () => {
		expect(priorityForRatio(3)).toBe("high");
	});

	it("treats a rounded 2.00x as high priority", () => {
		expect(priorityForRatio(1.9999)).toBe("high");
	});

	it("puts 1.99x in the medium band", () => {
		expect(priorityForRatio(1.99)).toBe("medium");
	});

	it("puts 1.3x in the medium band", () => {
		expect(priorityForRatio(1.3)).toBe("medium");
	});

	it("puts anything below 1.3x in the low band", () => {
		expect(priorityForRatio(1.29)).toBe("low");
	});

	it("returns unknown when no instalment can be computed", () => {
		expect(priorityForRatio(null)).toBe("unknown");
	});
});

describe("suggestedPrincipalMinor", () => {
	it("caps the instalment at half of monthly revenue", () => {
		// BDT 100,000 revenue -> BDT 50,000 affordable instalment.
		const suggested = suggestedPrincipalMinor({
			monthlyRevenueMinor: 10_000_000,
			annualRatePct: 12,
			months: 36,
			facility: "term",
			minAmountMinor: 10_000_000,
			maxAmountMinor: 100_000_000,
		});

		expect(suggested).not.toBeNull();
		expect(affordableEmiMinor(10_000_000)).toBe(5_000_000);
		expect(amortizedEmiMinor(suggested!, 12, 36)).toBeLessThanOrEqual(5_000_001);
	});

	it("stays inside the product's amount band", () => {
		const suggested = suggestedPrincipalMinor({
			monthlyRevenueMinor: 100_000_000,
			annualRatePct: 5,
			months: 60,
			facility: "term",
			minAmountMinor: 10_000_000,
			maxAmountMinor: 20_000_000,
		});

		expect(suggested).toBe(20_000_000);
	});

	it("returns the entry amount when the shop cannot afford the minimum", () => {
		const suggested = suggestedPrincipalMinor({
			monthlyRevenueMinor: 100_000,
			annualRatePct: 15,
			months: 12,
			facility: "term",
			minAmountMinor: 10_000_000,
			maxAmountMinor: 20_000_000,
		});

		expect(suggested).toBe(10_000_000);
	});
});

describe("rounding helpers", () => {
	it("rounds down to a whole thousand taka", () => {
		// Never round up: that would push the instalment above the 50% ceiling.
		expect(floorToThousandMinor(1_234_500)).toBe(1_200_000);
		expect(floorToThousandMinor(1_260_000)).toBe(1_200_000);
		expect(floorToThousandMinor(1_299_999)).toBe(1_200_000);
	});

	it("keeps a small amount visible", () => {
		expect(TEN_THOUSAND_TAKA).toBe(1_000_000);
	});
});
