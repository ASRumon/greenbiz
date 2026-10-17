import { Hono } from "hono";
import { eq } from "drizzle-orm";
import { z } from "zod";
import { creditProfiles } from "../db/schema";
import type { AppBindings } from "../lib/context";
import { currentUserId } from "../lib/context";
import { idParam, parseParams } from "../lib/validate";
import { requireAuth } from "../middleware/auth";
import { recomputeCreditProfile, REFERENCE_MONTHLY_INFLOW_MINOR, WINDOW_DAYS } from "../services/creditScore";
import { matchPlans, type MatchIntent } from "../services/planMatcher";
import { requireOwnedShop } from "../services/shopAccess";

export const creditRoutes = new Hono<AppBindings>();

// Per-route guards: this router is mounted at /api, so a wildcard middleware
// would leak onto the public routes mounted at the same prefix — and
// /credit/formula below is intentionally public.

const shopIdParam = z.object({ shopId: z.uuid("shopId must be a valid UUID") });

/**
 * Reads the stored profile, parsing the JSON `factors` column back into a typed
 * shape. The column is TEXT, so it is validated with Zod on read as well as on
 * write - a hand-edited row should not crash the Finance tab.
 */
const storedFactorsSchema = z.object({
	factors: z.array(
		z.object({
			name: z.enum(["consistency", "volume", "stability", "activity"]),
			score: z.number(),
			weight: z.number(),
			label: z.string(),
		}),
	),
	riskFlags: z.array(z.string()).default([]),
});

/* -------------------------------------------------------------------------- */
/* GET /api/shops/:shopId/credit                                               */
/* -------------------------------------------------------------------------- */

creditRoutes.get("/shops/:shopId/credit", requireAuth, async (c) => {
	const { shopId } = parseParams(c, shopIdParam);
	const db = c.get("db");

	await requireOwnedShop(db, shopId, currentUserId(c));

	const [stored] = await db
		.select()
		.from(creditProfiles)
		.where(eq(creditProfiles.shopId, shopId))
		.limit(1);

	if (!stored) {
		// Lazily create the profile so a brand-new shop sees a real 0-100 score
		// (with risk flags explaining why it is low) instead of an empty card.
		const computed = await recomputeCreditProfile(db, shopId);
		return c.json({
			creditProfile: {
				shopId,
				score: computed.score,
				factors: computed.factors,
				monthlyRevenueAvgMinor: computed.monthlyRevenueAvgMinor,
				monthlyVolatility: computed.monthlyVolatility,
				transactionCount90d: computed.transactionCount90d,
				riskFlags: computed.riskFlags,
				computedAt: computed.computedAt,
			},
			windowDays: WINDOW_DAYS,
			isFirstComputation: true,
		});
	}

	const parsed = storedFactorsSchema.safeParse(safeJsonParse(stored.factors));

	return c.json({
		creditProfile: {
			shopId: stored.shopId,
			score: stored.score,
			factors: parsed.success ? parsed.data.factors : [],
			monthlyRevenueAvgMinor: stored.monthlyRevenueAvgMinor,
			monthlyVolatility: stored.monthlyVolatility,
			transactionCount90d: stored.transactionCount90d,
			riskFlags: parsed.success ? parsed.data.riskFlags : [],
			computedAt: stored.computedAt,
		},
		windowDays: WINDOW_DAYS,
		isFirstComputation: false,
	});
});

/* -------------------------------------------------------------------------- */
/* POST /api/shops/:shopId/credit/recompute                                    */
/* -------------------------------------------------------------------------- */

creditRoutes.post("/shops/:shopId/credit/recompute", requireAuth, async (c) => {
	const { shopId } = parseParams(c, shopIdParam);
	const db = c.get("db");

	await requireOwnedShop(db, shopId, currentUserId(c));

	const computed = await recomputeCreditProfile(db, shopId);

	return c.json({
		creditProfile: {
			shopId,
			score: computed.score,
			factors: computed.factors,
			monthlyRevenueAvgMinor: computed.monthlyRevenueAvgMinor,
			monthlyVolatility: computed.monthlyVolatility,
			transactionCount90d: computed.transactionCount90d,
			riskFlags: computed.riskFlags,
			computedAt: computed.computedAt,
		},
		windowDays: WINDOW_DAYS,
	});
});

/* -------------------------------------------------------------------------- */
/* GET /api/shops/:shopId/matched-plans                                        */
/* -------------------------------------------------------------------------- */

creditRoutes.get("/shops/:shopId/matched-plans", requireAuth, async (c) => {
	const { shopId } = parseParams(c, shopIdParam);
	const db = c.get("db");

	await requireOwnedShop(db, shopId, currentUserId(c));

	const intent: MatchIntent = c.req.query("intent") === "insurance" ? "insurance" : "loan";
	const rawAmount = Number(c.req.query("amountMinor") ?? "");
	const requestedAmountMinor = Number.isFinite(rawAmount) && rawAmount > 0 ? Math.trunc(rawAmount) : undefined;

	const result = await matchPlans(db, shopId, intent, requestedAmountMinor);

	return c.json({
		matches: result.matches,
		capacity: result.capacity,
		monthlyRevenueMinor: result.monthlyRevenueMinor,
		// Rendered verbatim by the Finance tab. The estimate uses the shop's
		// recorded business revenue; it is not an approval.
		message:
			result.matches.length > 0
				? "Ranked by how comfortably your recorded business revenue covers each instalment. Estimates only — the lender decides."
				: "No active plan can be sized from your revenue yet. Record your business sales and try again.",
	});
});

/** Parses a TEXT JSON column, returning undefined instead of throwing. */
function safeJsonParse(value: string): unknown {
	try {
		return JSON.parse(value);
	} catch {
		return undefined;
	}
}

/**
 * The scoring weights and formula, exposed so the app (and a judge with a
 * calculator) can show the shop owner exactly how the number was reached.
 * No shop data is involved, so this is safe to serve without auth.
 */
creditRoutes.get("/credit/formula", (c) =>
	c.json({
		formula: "0.30*consistency + 0.25*volume + 0.25*stability + 0.20*activity",
		windowDays: WINDOW_DAYS,
		factors: [
			{ name: "consistency", weight: 0.3, description: "Even spread of inflow week to week" },
			{ name: "volume", weight: 0.25, description: "Monthly inflow against a reference turnover" },
			{ name: "stability", weight: 0.25, description: "Inverse of month-over-month volatility" },
			{ name: "activity", weight: 0.2, description: "Active-day ratio over the window" },
		],
		referenceMonthlyInflowMinor: REFERENCE_MONTHLY_INFLOW_MINOR,
	}),
);
