import { describe, expect, it } from "vitest";
import {
	computeCredit,
	FACTOR_WEIGHTS,
	REFERENCE_MONTHLY_INFLOW_MINOR,
	WINDOW_DAYS,
} from "../src/services/creditScore";
import { chunkForInsert, D1_MAX_BOUND_PARAMS } from "../src/lib/d1Limits";

/**
 * Credit scoring tests.
 *
 * `computeCredit` is a pure function precisely so it can be tested like this:
 * same input, same output, no database and no clock.
 */

const DAY = 24 * 60 * 60 * 1000;
const NOW = Date.UTC(2026, 9, 17, 12, 0, 0);

/** Builds a stream of inflow transactions every [everyDays] days. */
function inflowsEvery(days: number, count: number, amountMinor = 100000) {
	return Array.from({ length: count }, (_, index) => ({
		direction: "in" as const,
		amountMinor,
		occurredAt: NOW - index * days * DAY,
	}));
}

describe("factor weights", () => {
	it("sum to exactly 1", () => {
		const total = Object.values(FACTOR_WEIGHTS).reduce((sum, weight) => sum + weight, 0);
		expect(total).toBeCloseTo(1, 10);
	});

	it("match the documented formula", () => {
		expect(FACTOR_WEIGHTS.consistency).toBeCloseTo(0.3, 10);
		expect(FACTOR_WEIGHTS.volume).toBeCloseTo(0.25, 10);
		expect(FACTOR_WEIGHTS.stability).toBeCloseTo(0.25, 10);
		expect(FACTOR_WEIGHTS.activity).toBeCloseTo(0.2, 10);
	});
});

describe("computeCredit", () => {
	it("returns a score in 0-100 and all four factors", () => {
		const result = computeCredit({ transactions: inflowsEvery(3, 30), now: NOW });

		expect(result.score).toBeGreaterThanOrEqual(0);
		expect(result.score).toBeLessThanOrEqual(100);
		expect(result.factors).toHaveLength(4);
		expect(result.factors.map((factor) => factor.name)).toEqual([
			"consistency",
			"volume",
			"stability",
			"activity",
		]);
		expect(result.computedAt).toBe(NOW);
	});

	it("scores zero for a shop with no transactions", () => {
		const result = computeCredit({ transactions: [], now: NOW });

		expect(result.score).toBe(0);
		expect(result.monthlyRevenueAvgMinor).toBe(0);
		expect(result.transactionCount90d).toBe(0);
		expect(result.riskFlags).toContain("no_activity");
		expect(result.riskFlags).toContain("no_inflow");
	});

	it("ignores transactions older than the 90-day window", () => {
		const recent = inflowsEvery(3, 10);
		const stale = [
			{ direction: "in" as const, amountMinor: 100000, occurredAt: NOW - (WINDOW_DAYS + 5) * DAY },
			{ direction: "in" as const, amountMinor: 100000, occurredAt: NOW - 200 * DAY },
		];

		const withStale = computeCredit({ transactions: [...recent, ...stale], now: NOW });
		const withoutStale = computeCredit({ transactions: recent, now: NOW });

		expect(withStale.score).toBe(withoutStale.score);
		expect(withStale.transactionCount90d).toBe(recent.length);
	});

	it("ignores outflow when measuring revenue", () => {
		const inflows = inflowsEvery(3, 10, 100000);
		const withOutflow = computeCredit({
			transactions: [
				...inflows,
				{ direction: "out" as const, amountMinor: 500000, occurredAt: NOW - DAY },
			],
			now: NOW,
		});

		const inflowOnly = computeCredit({ transactions: inflows, now: NOW });
		expect(withOutflow.monthlyRevenueAvgMinor).toBe(inflowOnly.monthlyRevenueAvgMinor);
	});

	it("rewards steadier revenue with a higher stability score", () => {
		// Three months, same total, different spread.
		const steady = [
			{ direction: "in" as const, amountMinor: 2000000, occurredAt: NOW - 10 * DAY },
			{ direction: "in" as const, amountMinor: 2000000, occurredAt: NOW - 40 * DAY },
			{ direction: "in" as const, amountMinor: 2000000, occurredAt: NOW - 70 * DAY },
		];
		const erratic = [
			{ direction: "in" as const, amountMinor: 5900000, occurredAt: NOW - 10 * DAY },
			{ direction: "in" as const, amountMinor: 100000, occurredAt: NOW - 40 * DAY },
			{ direction: "in" as const, amountMinor: 0, occurredAt: NOW - 70 * DAY },
		];

		const steadyResult = computeCredit({ transactions: steady, now: NOW });
		const erraticResult = computeCredit({ transactions: erratic, now: NOW });

		const stabilityOf = (result: typeof steadyResult) =>
			result.factors.find((factor) => factor.name === "stability")!.score;

		expect(stabilityOf(steadyResult)).toBeGreaterThan(stabilityOf(erraticResult));
		expect(steadyResult.monthlyVolatility).toBeLessThan(erraticResult.monthlyVolatility);
	});

	it("scores volume against the reference turnover", () => {
		// 30 transactions of 100,000 minor over 90 days ~= 1,000,000/month,
		// which is half the reference, so volume should be about 50.
		const result = computeCredit({
			transactions: inflowsEvery(3, 30, 100000),
			now: NOW,
			referenceMonthlyInflowMinor: 2000000,
		});

		const volume = result.factors.find((factor) => factor.name === "volume")!.score;
		expect(volume).toBeGreaterThan(40);
		expect(volume).toBeLessThan(60);
	});

	it("reaches a full volume score at the reference turnover", () => {
		// 3 transactions of 2,000,000 minor across the window, spaced monthly.
		const result = computeCredit({
			transactions: [
				{ direction: "in" as const, amountMinor: 2000000, occurredAt: NOW - 5 * DAY },
				{ direction: "in" as const, amountMinor: 2000000, occurredAt: NOW - 35 * DAY },
				{ direction: "in" as const, amountMinor: 2000000, occurredAt: NOW - 65 * DAY },
			],
			now: NOW,
			referenceMonthlyInflowMinor: REFERENCE_MONTHLY_INFLOW_MINOR,
		});

		expect(result.factors.find((factor) => factor.name === "volume")!.score).toBeGreaterThan(90);
	});

	it("flags low activity when most days are empty", () => {
		const result = computeCredit({
			transactions: [
				{ direction: "in" as const, amountMinor: 100000, occurredAt: NOW - 2 * DAY },
				{ direction: "in" as const, amountMinor: 100000, occurredAt: NOW - 4 * DAY },
			],
			now: NOW,
		});

		expect(result.riskFlags).toContain("low_activity");
		expect(result.riskFlags).toContain("insufficient_history");
	});

	it("flags declining revenue when the latest month collapses", () => {
		const result = computeCredit({
			transactions: [
				// This month: tiny.
				{ direction: "in" as const, amountMinor: 10000, occurredAt: NOW - 2 * DAY },
				// Last month: healthy.
				{ direction: "in" as const, amountMinor: 3000000, occurredAt: NOW - 35 * DAY },
			],
			now: NOW,
		});

		expect(result.riskFlags).toContain("revenue_declining");
	});

	it("flags counterparty concentration when one payer dominates", () => {
		const result = computeCredit({
			transactions: [
				{ direction: "in" as const, amountMinor: 9000000, occurredAt: NOW - 5 * DAY, counterparty: "01711111111" },
				{ direction: "in" as const, amountMinor: 100000, occurredAt: NOW - 10 * DAY, counterparty: "01722222222" },
			],
			now: NOW,
		});

		expect(result.riskFlags).toContain("counterparty_concentration");
	});

	it("does not flag concentration when revenue is spread across payers", () => {
		const result = computeCredit({
			transactions: [
				{ direction: "in" as const, amountMinor: 1000000, occurredAt: NOW - 5 * DAY, counterparty: "A" },
				{ direction: "in" as const, amountMinor: 1000000, occurredAt: NOW - 10 * DAY, counterparty: "B" },
				{ direction: "in" as const, amountMinor: 1000000, occurredAt: NOW - 15 * DAY, counterparty: "C" },
			],
			now: NOW,
		});

		expect(result.riskFlags).not.toContain("counterparty_concentration");
	});

	it("is deterministic", () => {
		const transactions = inflowsEvery(4, 20);
		const first = computeCredit({ transactions, now: NOW });
		const second = computeCredit({ transactions, now: NOW });
		expect(first).toEqual(second);
	});

	it("never returns a fractional score or a negative one", () => {
		for (const count of [1, 2, 5, 15, 40, 90]) {
			const result = computeCredit({ transactions: inflowsEvery(1, count), now: NOW });
			expect(Number.isInteger(result.score)).toBe(true);
			expect(result.score).toBeGreaterThanOrEqual(0);
			expect(result.score).toBeLessThanOrEqual(100);
		}
	});
});

describe("chunkForInsert", () => {
	it("keeps every chunk under the D1 bound-parameter limit", () => {
		// 14 institutions x 8 columns = 112 params, which is what broke the
		// original single-statement seed.
		const rows = Array.from({ length: 14 }, (_, index) => ({ id: index }));
		const chunks = chunkForInsert(rows, 8);

		expect(chunks.length).toBeGreaterThan(1);
		for (const chunk of chunks) {
			expect(chunk.length * 8).toBeLessThanOrEqual(D1_MAX_BOUND_PARAMS);
		}
		expect(chunks.flat()).toHaveLength(14);
	});

	it("preserves row order", () => {
		const rows = Array.from({ length: 30 }, (_, index) => ({ id: index }));
		expect(chunkForInsert(rows, 16).flat()).toEqual(rows);
	});

	it("handles an empty list and a single row", () => {
		expect(chunkForInsert([], 8)).toEqual([]);
		expect(chunkForInsert([{ id: 1 }], 8)).toHaveLength(1);
	});

	it("always produces at least one row per chunk", () => {
		// A column count above the parameter limit must not yield zero-size
		// chunks and an infinite loop.
		const chunks = chunkForInsert([{ id: 1 }, { id: 2 }], 500);
		expect(chunks).toHaveLength(2);
		expect(chunks.every((chunk) => chunk.length === 1)).toBe(true);
	});
});
