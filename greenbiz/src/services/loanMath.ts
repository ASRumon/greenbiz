/**
 * Loan affordability maths.
 *
 * Pure functions only: same input, same output, no database and no clock. That
 * is what lets the ranking be explained to a shop owner and tested without a
 * Worker request.
 *
 * Conventions:
 * - Rates are percentages per annum (e.g. 12.5 means 12.5%).
 * - Money is an integer in minor units (poisha). Results are rounded, never
 *   floating point, so the API never returns a fraction of a poisha.
 * - A "term" facility repays principal + interest monthly. A revolving,
 *   interest-only or bullet facility services only interest each month, which
 *   is how the source comparison table estimates cash credit and overdrafts.
 */

export type RepaymentFacility = "term" | "revolving" | "interest_only" | "bullet";

export type MatchPriority = "high" | "medium" | "low" | "unknown";

/**
 * The shop's monthly revenue must cover the instalment at least this many
 * times to be called high priority. The product owner's rule: twice or thrice
 * the repayable amount is comfortable.
 */
export const PRIORITY_RATIO_HIGH = 2;
export const PRIORITY_RATIO_MEDIUM = 1.3;

/**
 * Share of monthly revenue a lender would typically let a microbusiness spend
 * on debt service. Keeping the instalment at half of revenue is exactly the
 * 2x cover that makes a plan "high priority".
 */
export const MAX_DEBT_SERVICE_RATIO = 0.5;

/** Tenor used when a product does not publish one. */
export const DEFAULT_TENOR_MONTHS = 36;

const clamp = (value: number, min: number, max: number) =>
	Math.min(max, Math.max(min, value));

export function monthlyRate(annualRatePct: number): number {
	return annualRatePct / 100 / 12;
}

/**
 * Equal monthly instalment (principal + interest).
 *
 * Standard amortisation: EMI = P * r * (1+r)^n / ((1+r)^n - 1).
 * A zero rate falls back to simple division instead of dividing by zero.
 */
export function amortizedEmiMinor(
	principalMinor: number,
	annualRatePct: number,
	months: number,
): number {
	if (principalMinor <= 0) return 0;
	if (months <= 0) return Math.round(principalMinor);

	const rate = monthlyRate(annualRatePct);
	if (rate <= 0) return Math.round(principalMinor / months);

	const growth = (1 + rate) ** months;
	return Math.round((principalMinor * rate * growth) / (growth - 1));
}

/**
 * Largest principal that a given monthly instalment can service.
 *
 * This is the inverse of [amortizedEmiMinor] and is how the app answers
 * "how much loan can my revenue support?".
 */
export function affordablePrincipalMinor(
	emiMinor: number,
	annualRatePct: number,
	months: number,
): number {
	if (emiMinor <= 0) return 0;
	if (months <= 0) return Math.round(emiMinor);

	const rate = monthlyRate(annualRatePct);
	if (rate <= 0) return Math.round(emiMinor * months);

	const growth = (1 + rate) ** months;
	return Math.round((emiMinor * (growth - 1)) / (rate * growth));
}

/** Interest serviced monthly on a revolving / bullet facility. */
export function interestOnlyEmiMinor(
	principalMinor: number,
	annualRatePct: number,
): number {
	if (principalMinor <= 0) return 0;
	return Math.round(principalMinor * monthlyRate(annualRatePct));
}

export function repaymentEmiMinor(
	principalMinor: number,
	annualRatePct: number,
	months: number,
	facility: RepaymentFacility,
): number {
	if (facility === "revolving" || facility === "interest_only" || facility === "bullet") {
		return interestOnlyEmiMinor(principalMinor, annualRatePct);
	}
	return amortizedEmiMinor(principalMinor, annualRatePct, months);
}

/** How many times the monthly revenue covers the instalment. */
export function affordabilityRatio(
	monthlyRevenueMinor: number,
	emiMinor: number,
): number | null {
	if (emiMinor <= 0 || monthlyRevenueMinor < 0) return null;
	return monthlyRevenueMinor / emiMinor;
}

export function priorityForRatio(ratio: number | null): MatchPriority {
	if (ratio === null || !Number.isFinite(ratio)) return "unknown";

	// Absorb the rounding in "round the suggested amount down to 1,000 taka":
	// a true 2.00x can land at 1.9999 and must not be labelled "medium".
	const epsilon = 0.005;
	if (ratio >= PRIORITY_RATIO_HIGH - epsilon) return "high";
	if (ratio >= PRIORITY_RATIO_MEDIUM - epsilon) return "medium";
	return "low";
}

/** Instalment a lender would consider comfortable: half of monthly revenue. */
export function affordableEmiMinor(monthlyRevenueMinor: number): number {
	return Math.max(0, Math.round(monthlyRevenueMinor * MAX_DEBT_SERVICE_RATIO));
}

/**
 * Principal supported at a plan's rate and tenor, kept inside the product's
 * published amount band. Returns null when the product cannot serve any amount
 * the shop can afford.
 */
export function suggestedPrincipalMinor(options: {
	monthlyRevenueMinor: number;
	annualRatePct: number;
	months: number;
	facility: RepaymentFacility;
	minAmountMinor?: number | null;
	maxAmountMinor?: number | null;
}): number | null {
	const { monthlyRevenueMinor, annualRatePct, months, facility } = options;

	const emi = affordableEmiMinor(monthlyRevenueMinor);
	if (emi <= 0) return null;

	// Both term and interest-only facilities use the same inverse formula: for
	// a revolving line the "months" value is the yearly renewal period, so the
	// derived principal still represents the line the shop can service.
	const principal = affordablePrincipalMinor(emi, annualRatePct, months);

	const floor = options.minAmountMinor ?? 0;
	const ceiling = options.maxAmountMinor ?? Number.MAX_SAFE_INTEGER;

	if (principal < floor) {
		// The shop cannot afford even the product's minimum ticket. Report the
		// minimum as the amount the product would need, so the UI can say
		// "this starts at X, which is above your comfort level".
		return floor > 0 ? floor : null;
	}

	return Math.round(clamp(principal, floor, ceiling));
}

/**
 * Rounds down to a whole thousand taka.
 *
 * Rounding down (not to nearest) is deliberate: the suggested principal must
 * never push the instalment above the 50% of revenue ceiling, otherwise a
 * "2x" plan would be labelled below 2x by a few poisha.
 */
export function floorToThousandMinor(amountMinor: number): number {
	if (amountMinor <= 0) return 0;
	return Math.floor(amountMinor / 100_000) * 100_000;
}

export function normalizeFacility(value: unknown): RepaymentFacility {
	return value === "revolving" || value === "interest_only" || value === "bullet"
		? value
		: "term";
}
