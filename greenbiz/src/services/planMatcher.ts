import { and, eq, or } from "drizzle-orm";
import type { Database } from "../db/client";
import {
	financialInstitutions,
	financialServicePlans,
	shops,
	type PlanRow,
} from "../db/schema";
import { monthlyRevenueMinorForShop } from "./creditScore";
import {
	affordabilityRatio,
	affordableEmiMinor,
	affordablePrincipalMinor,
	amortizedEmiMinor,
	DEFAULT_TENOR_MONTHS,
	floorToThousandMinor,
	normalizeFacility,
	priorityForRatio,
	repaymentEmiMinor,
	suggestedPrincipalMinor,
	type MatchPriority,
	type RepaymentFacility,
} from "./loanMath";

/**
 * Loan matching.
 *
 * The catalogue is the real Bangladeshi SME product table supplied on
 * 2026-10-18. Every number the matcher uses comes from the database row, never
 * from a hard-coded list, so updating `seed/plans.json` is enough to change the
 * recommendation set.
 *
 * Ranking is deliberately explainable:
 *
 *   1. affordability - the shop's average monthly business inflow against the
 *      instalment the plan implies. Revenue covering the instalment twice is
 *      the product rule for "high priority".
 *   2. cost - the lowest stated annual rate, not an unstated "market rate".
 *   3. institution trust - commercial bank > NBFI > MFI, and a published
 *      source URL beats no source.
 *   4. eligibility fit - known blockers (amount band, minimum revenue) reduce
 *      the score and produce a warning instead of silently hiding the plan.
 *
 * The response is indicative, not an approval. Lenders also check collateral,
 * CIB history and documents the app does not hold.
 */

export type MatchIntent = "loan" | "insurance";

export interface PlanMatch {
	plan: PlanRow;
	institutionName: string;
	institutionType: string;
	/** 0-1, higher is a better fit. */
	fitScore: number;
	/** Affordability band, driven by the revenue-to-instalment ratio. */
	priority: MatchPriority;
	emiMinor: number | null;
	/** Principal the shop can comfortably service on this product. */
	suggestedAmountMinor: number | null;
	/** monthlyRevenue / emi. 2 or more is high priority. */
	affordabilityRatio: number | null;
	interestRatePct: number | null;
	tenorMonths: number | null;
	facility: RepaymentFacility;
	/** Human-readable justification, rendered under the plan card. */
	reasons: string[];
	/** What the lender will ask for that this app cannot verify. */
	requirements: string[];
	/** Known mismatches with the shop's recorded data. */
	warnings: string[];
}

/**
 * How much the shop can borrow, and what that estimate is based on.
 *
 * `suggestedAmountMinor` is the largest principal whose instalment stays at or
 * below half of average monthly business revenue, inside a real product's
 * amount band where one fits.
 */
export interface LoanCapacity {
	monthlyRevenueMinor: number;
	maxAffordableEmiMinor: number;
	suggestedAmountMinor: number;
	tenorMonths: number;
	interestRatePct: number;
	facility: RepaymentFacility;
	affordabilityRatio: number | null;
	priority: MatchPriority;
	/** matched_plan | indicative_benchmark | insufficient_revenue */
	basis: "matched_plan" | "indicative_benchmark" | "insufficient_revenue";
	assumptions: string[];
}

export interface PlanMatchResult {
	matches: PlanMatch[];
	capacity: LoanCapacity | null;
	monthlyRevenueMinor: number;
}

/** Enough to fill a card without turning the response into the whole directory. */
const MATCH_LIMIT = 12;

/** Fallback sizing when no catalogue product can be evaluated yet. */
const BENCHMARK_RATE_PCT = 12;
const BENCHMARK_TENOR_MONTHS = 36;

const clamp = (value: number, min: number, max: number) =>
	Math.min(max, Math.max(min, value));

/** `৳12,500` without floating point. */
function formatMoney(minor: number): string {
	const whole = Math.round(minor / 100);
	return `৳${whole.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",")}`;
}

function parseJson(value: string | null): Record<string, unknown> | null {
	if (!value) return null;
	try {
		const parsed: unknown = JSON.parse(value);
		return parsed && typeof parsed === "object" && !Array.isArray(parsed)
			? (parsed as Record<string, unknown>)
			: null;
	} catch {
		return null;
	}
}

function numberOrNull(value: unknown): number | null {
	return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function institutionTrust(institutionType: string): number {
	switch (institutionType) {
		case "commercial_bank":
			return 1;
		case "nbfi":
			return 0.85;
		case "insurance":
			return 0.9;
		case "fintech":
			return 0.8;
		case "mfi":
			return 0.75;
		case "cooperative":
			return 0.7;
		default:
			return 0.6;
	}
}

interface PlanEvaluation {
	match: PlanMatch;
	score: number;
}

function evaluatePlan(options: {
	plan: PlanRow;
	institutionName: string;
	institutionType: string;
	monthlyRevenueMinor: number;
	shopAgeMonths: number;
	intent: MatchIntent;
	requestedAmountMinor?: number;
}): PlanEvaluation {
	const { plan, institutionName, institutionType, monthlyRevenueMinor, shopAgeMonths } =
		options;

	const eligibility = parseJson(plan.eligibilityCriteria) ?? {};
	const fees = parseJson(plan.feesDetails) ?? {};

	const facility = normalizeFacility(fees.facility);
	const assumedTenor = numberOrNull(fees.assumedTenorMonths);
	const tenorMonths = plan.durationMonths ?? assumedTenor ?? DEFAULT_TENOR_MONTHS;
	const interestRatePct = plan.interestRateMin ?? plan.interestRateMax ?? null;

	const minAmountMinor = plan.minAmountMinor;
	const maxAmountMinor = plan.maxAmountMinor;
	const requested = options.requestedAmountMinor;

	const reasons: string[] = [];
	const requirements: string[] = [];
	const warnings: string[] = [];

	/* -------------------------------------------------------------------- */
	/* Principal: the owner's requested amount, or what the revenue supports */
	/* -------------------------------------------------------------------- */

	let principalMinor: number | null = null;
	let amountBasis: "requested" | "affordable" | "minimum" | "none" = "none";
	let requestedFits = true;

	if (requested !== undefined) {
		principalMinor = clamp(
			requested,
			minAmountMinor ?? 0,
			maxAmountMinor ?? Number.MAX_SAFE_INTEGER,
		);
		amountBasis = "requested";
		requestedFits =
			(minAmountMinor === null || requested >= minAmountMinor) &&
			(maxAmountMinor === null || requested <= maxAmountMinor);

		reasons.push(`You asked for ${formatMoney(requested)}.`);
		if (!requestedFits) {
			warnings.push(
				`This product lends ${minAmountMinor !== null ? formatMoney(minAmountMinor) : "any amount"}${
					maxAmountMinor !== null ? ` to ${formatMoney(maxAmountMinor)}` : ""
				}.`,
			);
			if (minAmountMinor !== null && requested < minAmountMinor) {
				principalMinor = minAmountMinor;
			}
		}
	} else if (interestRatePct !== null && tenorMonths > 0) {
		const suggested = suggestedPrincipalMinor({
			monthlyRevenueMinor,
			annualRatePct: interestRatePct,
			months: tenorMonths,
			facility,
			minAmountMinor,
			maxAmountMinor,
		});
		principalMinor = suggested;
		amountBasis = suggested !== null ? "affordable" : "none";
	} else if (minAmountMinor !== null) {
		// No published rate means no instalment can be estimated. Show the entry
		// ticket so the plan is still visible and ranked on trust and fit.
		principalMinor = minAmountMinor;
		amountBasis = "minimum";
	}

	/* -------------------------------------------------------------------- */
	/* Instalment and affordability                                          */
	/* -------------------------------------------------------------------- */

	let emiMinor: number | null = null;
	let ratio: number | null = null;

	if (options.intent === "loan" && principalMinor !== null && interestRatePct !== null) {
		emiMinor = repaymentEmiMinor(
			principalMinor,
			interestRatePct,
			tenorMonths,
			facility,
		);

		// A revolving line only services interest, but comparing that against
		// revenue would make every cash credit look 30x affordable. Affordability
		// therefore assumes the principal is repaid over the renewal period, which
		// is the same debt-service test a term loan gets.
		const affordabilityEmi = amortizedEmiMinor(
			principalMinor,
			interestRatePct,
			tenorMonths,
		);
		ratio = affordabilityRatio(monthlyRevenueMinor, affordabilityEmi);
	}

	const priority = priorityForRatio(ratio);

	const revolving = facility === "revolving" || facility === "interest_only";

	if (emiMinor !== null) {
		reasons.push(
			revolving
				? `Interest-only about ${formatMoney(emiMinor)}/month at ${interestRatePct!.toFixed(2)}% p.a.; affordability is checked as if the principal were repaid over ${tenorMonths} months.`
				: `Instalment about ${formatMoney(emiMinor)}/month at ${interestRatePct!.toFixed(2)}% p.a. over ${tenorMonths} months.`,
		);
	}

	if (ratio !== null && monthlyRevenueMinor > 0) {
		const coverage = ratio.toFixed(1);
		if (priority === "high") {
			reasons.push(
				`Your average business revenue (${formatMoney(monthlyRevenueMinor)}/month) covers this ${coverage}× — high priority.`,
			);
		} else if (priority === "medium") {
			reasons.push(
				`Your average revenue covers this ${coverage}× — possible, but keep a cash buffer.`,
			);
		} else {
			reasons.push(
				`Your average revenue covers this ${coverage}× — below the 2× comfort rule.`,
			);
		}
	} else if (monthlyRevenueMinor <= 0 && options.intent === "loan") {
		warnings.push(
			"No business revenue is recorded yet, so affordability cannot be checked.",
		);
	}

	if (amountBasis === "affordable" && principalMinor !== null) {
		reasons.push(
			`At half of your monthly revenue, this plan supports about ${formatMoney(
				floorToThousandMinor(principalMinor),
			)}.`,
		);
	} else if (amountBasis === "minimum" && principalMinor !== null) {
		reasons.push(
			`Published terms do not state a rate, so ${formatMoney(principalMinor)} is the entry amount shown.`,
		);
	}

	/* -------------------------------------------------------------------- */
	/* What the lender will ask for                                          */
	/* -------------------------------------------------------------------- */

	const requiresCollateral = eligibility.requiresCollateral;
	if (requiresCollateral === true) {
		requirements.push(
			typeof eligibility.collateralNote === "string"
				? `Collateral: ${eligibility.collateralNote}`
				: "Collateral or mortgage required",
		);
	} else if (requiresCollateral === false) {
		requirements.push(
			typeof eligibility.collateralNote === "string"
				? `Unsecured: ${eligibility.collateralNote}`
				: "No collateral required",
		);
	}

	const guarantors = numberOrNull(eligibility.guarantorsRequired);
	if (guarantors !== null && guarantors > 0) {
		requirements.push(
			`${guarantors} personal guarantee${guarantors === 1 ? "" : "s"}`,
		);
	}

	const minBusinessAgeMonths = numberOrNull(eligibility.minBusinessAgeMonths);
	if (minBusinessAgeMonths !== null && minBusinessAgeMonths > 0) {
		const years = Math.round(minBusinessAgeMonths / 12);
		requirements.push(`Business age of at least ${years} year${years === 1 ? "" : "s"}`);
		if (shopAgeMonths < minBusinessAgeMonths) {
			warnings.push(
				`Your recorded business history is ${Math.max(0, Math.floor(shopAgeMonths))} months; the product asks for ${minBusinessAgeMonths}.`,
			);
		}
	}

	if (eligibility.womenOwned === true) {
		requirements.push("Women-led business");
	}

	const minAge = numberOrNull(eligibility.minAgeYears);
	const maxAge = numberOrNull(eligibility.maxAgeYears);
	if (minAge !== null || maxAge !== null) {
		requirements.push(
			minAge !== null && maxAge !== null
				? `Owner age ${minAge}–${maxAge}`
				: minAge !== null
					? `Owner age ${minAge}+`
					: `Owner age up to ${maxAge}`,
		);
	}

	if (eligibility.requiresTradeLicence === true) {
		requirements.push("Valid trade licence");
	}

	if (eligibility.requiresBankTransactions === true) {
		requirements.push("Bank transaction history");
	}

	if (typeof eligibility.other === "string" && eligibility.other.length > 0) {
		requirements.push(eligibility.other);
	}

	const minMonthlyRevenueMinor = numberOrNull(eligibility.minMonthlyRevenueMinor);
	if (minMonthlyRevenueMinor !== null) {
		requirements.push(
			`Monthly income of at least ${formatMoney(minMonthlyRevenueMinor)}`,
		);
		if (monthlyRevenueMinor < minMonthlyRevenueMinor) {
			warnings.push(
				`Your average revenue (${formatMoney(monthlyRevenueMinor)}/month) is below this product's minimum.`,
			);
		}
	}

	/* -------------------------------------------------------------------- */
	/* Score                                                                 */
	/* -------------------------------------------------------------------- */

	const affordabilityScore =
		options.intent === "insurance"
			? 0.45
			: ratio === null
				? monthlyRevenueMinor > 0
					? 0.15
					: 0
				: clamp(ratio / 3, 0, 1);

	const costScore =
		interestRatePct === null
			? 0.3
			: clamp(1 - (interestRatePct - 4) / 16, 0, 1);

	const trustScore = institutionTrust(institutionType) * (plan.sourceUrl ? 1 : 0.9);

	let eligibilityScore = 1;
	if (!requestedFits) eligibilityScore -= 0.4;
	if (
		minMonthlyRevenueMinor !== null &&
		monthlyRevenueMinor < minMonthlyRevenueMinor
	) {
		eligibilityScore -= 0.3;
	}
	if (
		minBusinessAgeMonths !== null &&
		shopAgeMonths < minBusinessAgeMonths
	) {
		eligibilityScore -= 0.2;
	}
	eligibilityScore = clamp(eligibilityScore, 0, 1);

	const rawScore =
		affordabilityScore * 0.55 +
		costScore * 0.25 +
		trustScore * 0.12 +
		eligibilityScore * 0.08;

	const match: PlanMatch = {
		plan,
		institutionName,
		institutionType,
		fitScore: Number(clamp(rawScore, 0, 1).toFixed(4)),
		priority,
		emiMinor,
		suggestedAmountMinor:
			principalMinor === null ? null : floorToThousandMinor(principalMinor),
		affordabilityRatio: ratio === null ? null : Number(ratio.toFixed(2)),
		interestRatePct,
		tenorMonths: interestRatePct === null ? null : tenorMonths,
		facility,
		reasons,
		requirements,
		warnings,
	};

	return { match, score: match.fitScore };
}

/**
 * Builds the "how much can I borrow?" answer from the best matched plan.
 *
 * The estimate deliberately uses half of average monthly revenue as the
 * instalment ceiling. That is the same 2x rule used for the high-priority band,
 * so the headline amount and the plan labels cannot contradict each other.
 */
function capacityFrom(
	matches: PlanMatch[],
	monthlyRevenueMinor: number,
): { capacity: LoanCapacity; plan: PlanMatch | null } {
	if (monthlyRevenueMinor <= 0) {
		return {
			capacity: {
				monthlyRevenueMinor,
				maxAffordableEmiMinor: 0,
				suggestedAmountMinor: 0,
				tenorMonths: 0,
				interestRatePct: 0,
				facility: "term",
				affordabilityRatio: null,
				priority: "unknown",
				basis: "insufficient_revenue",
				assumptions: [
					"Record business sales for at least a month so the estimate has revenue to work from.",
				],
			},
			plan: null,
		};
	}

	// The headline capacity is the largest amount the shop can service inside a
	// real product band. Term plans are preferred because a revolving line is a
	// rolling facility, not a fixed loan. Sorting by amount (not by fit score)
	// is what makes the number an answer to "how much can I borrow?".
	const usable = matches.filter(
		(match) =>
			match.emiMinor !== null &&
			match.suggestedAmountMinor !== null &&
			match.suggestedAmountMinor > 0,
	);

	const pick = (pool: PlanMatch[]): PlanMatch | undefined => {
		if (pool.length === 0) return undefined;
		const termPlans = pool.filter(
			(match) => match.facility === "term" && (match.tenorMonths ?? 0) <= 72,
		);
		const candidates = termPlans.length > 0 ? termPlans : pool;
		return [...candidates].sort(
			(a, b) =>
				(b.suggestedAmountMinor ?? 0) - (a.suggestedAmountMinor ?? 0),
		)[0];
	};

	const preferred =
		pick(usable.filter((match) => match.priority === "high")) ??
		pick(usable.filter((match) => match.priority === "medium")) ??
		pick(usable);

	if (preferred && preferred.suggestedAmountMinor !== null) {
		return {
			capacity: {
				monthlyRevenueMinor,
				maxAffordableEmiMinor: affordableEmiMinor(monthlyRevenueMinor),
				suggestedAmountMinor: preferred.suggestedAmountMinor,
				tenorMonths: preferred.tenorMonths ?? DEFAULT_TENOR_MONTHS,
				interestRatePct: preferred.interestRatePct ?? BENCHMARK_RATE_PCT,
				facility: preferred.facility,
				affordabilityRatio: preferred.affordabilityRatio,
				priority: preferred.priority,
				basis: "matched_plan",
				assumptions: [
					"Instalment is capped at 50% of your average monthly business revenue.",
					`Based on ${preferred.institutionName} — ${preferred.plan.planName}.`,
					"Uses the plan's lowest stated rate and published tenor.",
					"Indicative only. The lender checks collateral, CIB and documents.",
				],
			},
			plan: preferred,
		};
	}

	const emi = affordableEmiMinor(monthlyRevenueMinor);
	const suggested = floorToThousandMinor(
		affordablePrincipalMinor(emi, BENCHMARK_RATE_PCT, BENCHMARK_TENOR_MONTHS),
	);

	return {
		capacity: {
			monthlyRevenueMinor,
			maxAffordableEmiMinor: emi,
			suggestedAmountMinor: suggested,
			tenorMonths: BENCHMARK_TENOR_MONTHS,
			interestRatePct: BENCHMARK_RATE_PCT,
			facility: "term",
			affordabilityRatio: affordabilityRatio(monthlyRevenueMinor, emi),
			priority: priorityForRatio(affordabilityRatio(monthlyRevenueMinor, emi)),
			basis: "indicative_benchmark",
			assumptions: [
				"Instalment is capped at 50% of your average monthly business revenue.",
				`Benchmark: ${BENCHMARK_RATE_PCT}% p.a. over ${BENCHMARK_TENOR_MONTHS} months, because no catalogue product could be sized yet.`,
				"Indicative only. The lender decides the final amount.",
			],
		},
		plan: null,
	};
}

export async function matchPlans(
	db: Database,
	shopId: string,
	intent: MatchIntent,
	requestedAmountMinor?: number,
): Promise<PlanMatchResult> {
	const now = Date.now();

	const [shop] = await db
		.select({ createdAt: shops.createdAt })
		.from(shops)
		.where(eq(shops.id, shopId))
		.limit(1);

	const shopAgeMonths = shop
		? (now - shop.createdAt) / (30 * 24 * 60 * 60 * 1000)
		: 0;

	const monthlyRevenueMinor = await monthlyRevenueMinorForShop(db, shopId, now);

	const typeFilter =
		intent === "insurance"
			? eq(financialServicePlans.serviceType, "insurance")
			: or(
					eq(financialServicePlans.serviceType, "loan"),
					eq(financialServicePlans.serviceType, "working_capital"),
				)!;

	const rows = await db
		.select({
			plan: financialServicePlans,
			institutionName: financialInstitutions.name,
			institutionType: financialInstitutions.institutionType,
		})
		.from(financialServicePlans)
		.innerJoin(
			financialInstitutions,
			eq(financialServicePlans.institutionId, financialInstitutions.id),
		)
		.where(and(eq(financialServicePlans.isActive, true), typeFilter));

	const sorted = rows
		.map((row) =>
			evaluatePlan({
				plan: row.plan,
				institutionName: row.institutionName,
				institutionType: row.institutionType,
				monthlyRevenueMinor,
				shopAgeMonths,
				intent,
				requestedAmountMinor,
			}).match,
		)
		.sort((a, b) => {
			// Highest priority first, then the explainable fit score, then the
			// cheaper instalment. Without the priority key a very cheap lender
			// could outrank a plan the shop can actually repay comfortably.
			const rank = { high: 0, medium: 1, low: 2, unknown: 3 } as const;
			const priorityDelta = rank[a.priority] - rank[b.priority];
			if (priorityDelta !== 0) return priorityDelta;
			if (b.fitScore !== a.fitScore) return b.fitScore - a.fitScore;
			return (a.emiMinor ?? Number.MAX_SAFE_INTEGER) - (b.emiMinor ?? Number.MAX_SAFE_INTEGER);
		});

	let matches = sorted.slice(0, MATCH_LIMIT);

	// Insurance products do not have a loan capacity. Only the loan intent gets
	// the "how much can I borrow?" estimate.
	const capacityResult =
		intent === "loan" ? capacityFrom(sorted, monthlyRevenueMinor) : null;

	// The headline estimate is based on one plan. Make sure that plan is in the
	// returned list, even when it sits just outside the top MATCH_LIMIT.
	if (capacityResult?.plan) {
		const planId = capacityResult.plan.plan.id;
		if (!matches.some((match) => match.plan.id === planId)) {
			matches = [capacityResult.plan, ...matches.slice(0, MATCH_LIMIT - 1)];
		}
	}

	return {
		matches,
		capacity: capacityResult?.capacity ?? null,
		monthlyRevenueMinor,
	};
}
