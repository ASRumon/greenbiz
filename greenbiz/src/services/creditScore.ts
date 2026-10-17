/**
 * Rule-based SME credit scoring.
 *
 * No ML, no black box: every number here can be explained to a shop owner in
 * one sentence, which is the point. A lender-facing model that cannot be
 * explained is not usable for a first-time borrower.
 *
 * Window: the trailing 90 days. All money is integer minor units.
 */

import { and, eq, gte } from "drizzle-orm";
import type { Database } from "../db/client";
import { creditProfiles, transactions } from "../db/schema";

export const WINDOW_DAYS = 90;
const DAY_MS = 24 * 60 * 60 * 1000;

/**
 * Monthly inflow that scores full marks on the Volume factor.
 *
 * 2,000,000 minor units = 20,000 BDT or INR per month, roughly the turnover of
 * the microbusinesses this app targets. Tune per market; it is the only
 * absolute number in the model, and the other three factors are scale-free.
 */
export const REFERENCE_MONTHLY_INFLOW_MINOR = 2_000_000;

/** Weights from the spec. Must sum to 1. */
export const FACTOR_WEIGHTS = {
	consistency: 0.3,
	volume: 0.25,
	stability: 0.25,
	activity: 0.2,
} as const;

export type FactorName = keyof typeof FACTOR_WEIGHTS;

export interface FactorScore {
	name: FactorName;
	/** 0-100 */
	score: number;
	weight: number;
	/** One-line human explanation, shown in the Flutter factor bars. */
	label: string;
}

export interface CreditResult {
	/** 0-100 */
	score: number;
	factors: FactorScore[];
	monthlyRevenueAvgMinor: number;
	/** 0-1 coefficient of variation across monthly inflow. */
	monthlyVolatility: number;
	transactionCount90d: number;
	riskFlags: string[];
	computedAt: number;
}

export interface CreditInput {
	direction: "in" | "out";
	amountMinor: number;
	occurredAt: number;
	/** Used for the concentration risk flag. */
	counterparty?: string | null;
}

/** Coefficient of variation (stddev / mean). Returns 0 for a single value. */
function coefficientOfVariation(values: number[]): number {
	if (values.length < 2) return 0;
	const mean = values.reduce((sum, value) => sum + value, 0) / values.length;
	if (mean <= 0) return 0;

	const variance =
		values.reduce((sum, value) => sum + (value - mean) ** 2, 0) / values.length;
	return Math.sqrt(variance) / mean;
}

const clamp = (value: number, min = 0, max = 100) => Math.min(max, Math.max(min, value));

/** UTC month key, so month boundaries do not shift with the device timezone. */
function monthKey(timestampMs: number): string {
	const date = new Date(timestampMs);
	return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}`;
}

/**
 * Computes the score from raw transactions.
 *
 * Pure function: same input always gives the same output, which is what makes
 * it testable without a database.
 */
export function computeCredit(input: {
	transactions: CreditInput[];
	now: number;
	referenceMonthlyInflowMinor?: number;
}): CreditResult {
	const { now } = input;
	const windowStart = now - WINDOW_DAYS * DAY_MS;
	const reference = input.referenceMonthlyInflowMinor ?? REFERENCE_MONTHLY_INFLOW_MINOR;

	const windowed = input.transactions.filter(
		(tx) => tx.occurredAt >= windowStart && tx.occurredAt <= now,
	);

	const inflows = windowed.filter((tx) => tx.direction === "in");
	const totalInflowMinor = inflows.reduce((sum, tx) => sum + tx.amountMinor, 0);

	/* ---------------------------------------------------------------------- */
	/* Activity - what fraction of the last 90 days had any traffic at all?    */
	/* ---------------------------------------------------------------------- */

	const activeDayKeys = new Set(
		windowed.map((tx) => Math.floor(tx.occurredAt / DAY_MS)),
	);
	const activeDayRatio = activeDayKeys.size / WINDOW_DAYS;
	const activity = clamp(activeDayRatio * 100);

	/* ---------------------------------------------------------------------- */
	/* Volume - average monthly inflow against the reference turnover.         */
	/* ---------------------------------------------------------------------- */

	// Denominator is the observed span, floored at 30 days. Extrapolating a
	// *monthly* figure from three days of sales would multiply a shop's turnover
	// by ten and hand it a volume score it has not earned, so a full month is
	// assumed until the shop has more than a month of history.
	const earliestInWindow = windowed.reduce(
		(min, tx) => Math.min(min, tx.occurredAt),
		now,
	);
	const observedDays = (now - earliestInWindow) / DAY_MS;
	const divisorDays = Math.min(WINDOW_DAYS, Math.max(30, observedDays));

	const monthlyRevenueAvgMinor = Math.round((totalInflowMinor / divisorDays) * 30);
	const volume = clamp((monthlyRevenueAvgMinor / reference) * 100);

	/* ---------------------------------------------------------------------- */
	/* Stability - inverse of month-over-month volatility.                     */
	/* ---------------------------------------------------------------------- */

	const monthlyInflow = new Map<string, number>();
	for (const tx of inflows) {
		const key = monthKey(tx.occurredAt);
		monthlyInflow.set(key, (monthlyInflow.get(key) ?? 0) + tx.amountMinor);
	}

	// Only count completed months plus the current one, and require at least two
	// data points: volatility of a single month is meaningless, not "perfect".
	const monthValues = [...monthlyInflow.entries()]
		.sort(([a], [b]) => a.localeCompare(b))
		.map(([, value]) => value);

	const monthlyVolatility = monthValues.length >= 2 ? coefficientOfVariation(monthValues) : 0;
	const stability = monthValues.length >= 2 ? clamp((1 - monthlyVolatility) * 100) : 0;

	/* ---------------------------------------------------------------------- */
	/* Consistency - are inflows spread evenly, week to week?                  */
	/* ---------------------------------------------------------------------- */

	const weeklyInflow: number[] = [];
	for (let week = 0; week < WINDOW_DAYS / 7; week += 1) {
		const weekEnd = now - week * 7 * DAY_MS;
		const weekStart = weekEnd - 7 * DAY_MS;
		const total = inflows
			.filter((tx) => tx.occurredAt > weekStart && tx.occurredAt <= weekEnd)
			.reduce((sum, tx) => sum + tx.amountMinor, 0);
		weeklyInflow.push(total);
	}

	// Weeks with zero inflow count. A shop that only sells on Saturdays gets a
	// low consistency score, which is the intent.
	const weeksWithInflow = weeklyInflow.filter((value) => value > 0).length;
	const weeklyCv = weeksWithInflow >= 2 ? coefficientOfVariation(weeklyInflow) : 0;
	const consistency = weeksWithInflow >= 2 ? clamp((1 - weeklyCv) * 100) : 0;

	/* ---------------------------------------------------------------------- */
	/* Score                                                                  */
	/* ---------------------------------------------------------------------- */

	const factors: FactorScore[] = [
		{
			name: "consistency",
			score: Math.round(consistency),
			weight: FACTOR_WEIGHTS.consistency,
			label: "How evenly sales are spread week to week",
		},
		{
			name: "volume",
			score: Math.round(volume),
			weight: FACTOR_WEIGHTS.volume,
			label: "Monthly money coming in, against a reference turnover",
		},
		{
			name: "stability",
			score: Math.round(stability),
			weight: FACTOR_WEIGHTS.stability,
			label: "How steady monthly revenue is (less swing is better)",
		},
		{
			name: "activity",
			score: Math.round(activity),
			weight: FACTOR_WEIGHTS.activity,
			label: "Share of the last 90 days with any recorded activity",
		},
	];

	const raw =
		consistency * FACTOR_WEIGHTS.consistency +
		volume * FACTOR_WEIGHTS.volume +
		stability * FACTOR_WEIGHTS.stability +
		activity * FACTOR_WEIGHTS.activity;

	/* ---------------------------------------------------------------------- */
	/* Risk flags                                                             */
	/* ---------------------------------------------------------------------- */

	const riskFlags: string[] = [];

	if (windowed.length === 0) riskFlags.push("no_activity");
	if (windowed.length > 0 && windowed.length < 10) riskFlags.push("insufficient_history");
	if (totalInflowMinor === 0) riskFlags.push("no_inflow");
	if (activeDayRatio < 0.15 && windowed.length > 0) riskFlags.push("low_activity");
	if (monthlyVolatility > 0.6) riskFlags.push("high_volatility");

	if (monthValues.length >= 2) {
		const previous = monthValues[monthValues.length - 2] ?? 0;
		const latest = monthValues[monthValues.length - 1] ?? 0;
		// Compare only when the previous month was material, otherwise a shop
		// going from one sale to two is flagged as "declining".
		if (previous > 0 && latest < previous * 0.7) riskFlags.push("revenue_declining");
	}

	if (totalInflowMinor > 0) {
		// A shop whose revenue all comes from one payer is fragile: if that
		// payer leaves, the business is gone overnight.
		const byCounterparty = new Map<string, number>();
		for (const tx of inflows) {
			const key = tx.counterparty?.trim().toLowerCase() || "unlabelled";
			byCounterparty.set(key, (byCounterparty.get(key) ?? 0) + tx.amountMinor);
		}

		const largest = Math.max(...byCounterparty.values());
		if (byCounterparty.size >= 2 && largest / totalInflowMinor > 0.85) {
			riskFlags.push("counterparty_concentration");
		}
	}

	return {
		score: Math.round(clamp(raw)),
		factors,
		monthlyRevenueAvgMinor,
		monthlyVolatility: Number(monthlyVolatility.toFixed(4)),
		transactionCount90d: windowed.length,
		riskFlags,
		computedAt: now,
	};
}

/**
 * Average monthly business inflow over the scoring window.
 *
 * Used by the loan matcher, which needs current revenue but must not write a
 * credit profile as a side effect of a GET request.
 */
export async function monthlyRevenueMinorForShop(
	db: Database,
	shopId: string,
	now = Date.now(),
): Promise<number> {
	const windowStart = now - WINDOW_DAYS * DAY_MS;

	const rows = await db
		.select({
			direction: transactions.direction,
			amountMinor: transactions.amountMinor,
			occurredAt: transactions.occurredAt,
		})
		.from(transactions)
		.where(
			and(
				eq(transactions.shopId, shopId),
				gte(transactions.occurredAt, windowStart),
				eq(transactions.isBusiness, true),
			),
		);

	return computeCredit({
		transactions: rows.map((row) => ({
			direction: row.direction === "out" ? "out" : "in",
			amountMinor: row.amountMinor,
			occurredAt: row.occurredAt,
		})),
		now,
	}).monthlyRevenueAvgMinor;
}

/**
 * Computes the profile for a shop and upserts it into `credit_profiles`.
 * Called after SMS ingestion and by the explicit recompute endpoint.
 */
export async function recomputeCreditProfile(
	db: Database,
	shopId: string,
	now = Date.now(),
): Promise<CreditResult> {
	const windowStart = now - WINDOW_DAYS * DAY_MS;

	const rows = await db
		.select({
			direction: transactions.direction,
			amountMinor: transactions.amountMinor,
			occurredAt: transactions.occurredAt,
			counterparty: transactions.counterparty,
		})
		.from(transactions)
		.where(
			and(
				eq(transactions.shopId, shopId),
				gte(transactions.occurredAt, windowStart),
				eq(transactions.isBusiness, true),
			),
		);

	const result = computeCredit({
		transactions: rows.map((row) => ({
			direction: row.direction === "out" ? "out" : "in",
			amountMinor: row.amountMinor,
			occurredAt: row.occurredAt,
			counterparty: row.counterparty,
		})),
		now,
	});

	await db
		.insert(creditProfiles)
		.values({
			shopId,
			score: result.score,
			factors: JSON.stringify({ factors: result.factors, riskFlags: result.riskFlags }),
			monthlyRevenueAvgMinor: result.monthlyRevenueAvgMinor,
			monthlyVolatility: result.monthlyVolatility,
			transactionCount90d: result.transactionCount90d,
			computedAt: result.computedAt,
		})
		.onConflictDoUpdate({
			target: creditProfiles.shopId,
			set: {
				score: result.score,
				factors: JSON.stringify({ factors: result.factors, riskFlags: result.riskFlags }),
				monthlyRevenueAvgMinor: result.monthlyRevenueAvgMinor,
				monthlyVolatility: result.monthlyVolatility,
				transactionCount90d: result.transactionCount90d,
				computedAt: result.computedAt,
			},
		});

	return result;
}
