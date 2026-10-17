import { Hono } from "hono";
import { and, desc, eq, gte } from "drizzle-orm";
import { z } from "zod";
import { creditProfiles, products, transactions } from "../db/schema";
import type { AppBindings } from "../lib/context";
import { currentUserId } from "../lib/context";
import { hasAnyAiProvider } from "../lib/env";
import { badRequest } from "../lib/errors";
import { optionalText } from "../lib/schemas";
import { parseJsonBody } from "../lib/validate";
import { requireAuth } from "../middleware/auth";
import { aiComplete } from "../services/ai";
import { WINDOW_DAYS } from "../services/creditScore";
import { matchPlans, type MatchIntent } from "../services/planMatcher";
import { requireOwnedShop } from "../services/shopAccess";
import { parseSms } from "../services/smsParser";

export const aiRoutes = new Hono<AppBindings>();

/**
 * Auth is required on every AI route.
 *
 * Without it these endpoints are an open, unauthenticated LLM proxy billed to
 * this project's API keys - anyone who finds the URL can drain the quota. The
 * keys themselves never leave the Worker; the client only ever sees text.
 */
aiRoutes.use("*", requireAuth);

/* -------------------------------------------------------------------------- */
/* Schemas                                                                     */
/* -------------------------------------------------------------------------- */

const recommendSchema = z.object({
	shopId: z.uuid("shopId must be a valid UUID"),
	intent: z.enum(["loan", "insurance"]),
	message: optionalText(500),
});

const parseSmsSchema = z.object({
	sender: z.string().trim().min(1, "sender is required").max(64),
	body: z.string().min(1, "body is required").max(2000),
});

/* -------------------------------------------------------------------------- */
/* POST /api/ai/recommend                                                      */
/* -------------------------------------------------------------------------- */

const ADVICE_SYSTEM_PROMPT = `You are a practical finance advisor for very small businesses in Bangladesh (bKash, Nagad, Rocket) and India (UPI).

Rules you must follow:
- Write for a shop owner, not an accountant. Plain sentences, no jargon, no markdown headings.
- Ground every statement in the numbers you are given. Never invent figures.
- If the data is too thin to say anything useful, say so plainly and tell the owner what to record.
- When a loan capacity estimate is provided, you may mention the affordable monthly instalment and the approximate loan it supports, but call it an estimate based on recorded sales.
- Never promise that a loan or policy will be approved. You can describe what lenders typically look for.
- Do not give tax, legal, or investment advice.
- Do not ask for or repeat any personal data such as phone numbers.
- Keep it under 180 words.`;

aiRoutes.post("/recommend", async (c) => {
	const input = await parseJsonBody(c, recommendSchema);
	const db = c.get("db");
	const shop = await requireOwnedShop(db, input.shopId, currentUserId(c));

	if (!hasAnyAiProvider(c.env)) {
		throw badRequest(
			"AI advice is not available because no AI provider is configured on the server. Add GEMINI_API_KEY as a Worker secret.",
		);
	}

	const windowStart = Date.now() - WINDOW_DAYS * 24 * 60 * 60 * 1000;

	const [profile] = await db
		.select()
		.from(creditProfiles)
		.where(eq(creditProfiles.shopId, shop.id))
		.limit(1);

	const recentTransactions = await db
		.select({
			direction: transactions.direction,
			amountMinor: transactions.amountMinor,
			currency: transactions.currency,
			occurredAt: transactions.occurredAt,
		})
		.from(transactions)
		.where(
			and(
				eq(transactions.shopId, shop.id),
				gte(transactions.occurredAt, windowStart),
				eq(transactions.isBusiness, true),
			),
		)
		.orderBy(desc(transactions.occurredAt))
		.limit(50);

	const inventory = await db
		.select({
			productName: products.productName,
			unitPriceMinor: products.unitPriceMinor,
			stockQuantity: products.stockQuantity,
		})
		.from(products)
		.where(eq(products.shopId, shop.id))
		.limit(50);

	// Aggregates go to the model, not raw SMS bodies. The model sees what the
	// shop earns, never the message text or the counterparty phone numbers.
	const inflowMinor = recentTransactions
		.filter((tx) => tx.direction === "in")
		.reduce((sum, tx) => sum + tx.amountMinor, 0);
	const outflowMinor = recentTransactions
		.filter((tx) => tx.direction === "out")
		.reduce((sum, tx) => sum + tx.amountMinor, 0);

	// The matcher runs before the model so the advice can use the same
	// affordability numbers the Finance tab shows. If no plan can be sized, the
	// capacity object still carries the benchmark or the "record more sales"
	// reason.
	const matchResult = await matchPlans(db, shop.id, input.intent as MatchIntent);

	const context = {
		shopName: shop.shopName,
		businessType: shop.businessType,
		intent: input.intent,
		currency: recentTransactions[0]?.currency ?? "BDT",
		creditScore: profile?.score ?? null,
		monthlyRevenueAvgMinor: profile?.monthlyRevenueAvgMinor ?? null,
		monthlyVolatility: profile?.monthlyVolatility ?? null,
		transactionCount90d: profile?.transactionCount90d ?? recentTransactions.length,
		inflowMinor90d: inflowMinor,
		outflowMinor90d: outflowMinor,
		productCount: inventory.length,
		stockValueMinor: inventory.reduce(
			(sum, item) => sum + Math.round(item.unitPriceMinor * item.stockQuantity),
			0,
		),
		loanCapacity: matchResult.capacity,
		topMatchedPlans: matchResult.matches.slice(0, 3).map((match) => ({
			institution: match.institutionName,
			plan: match.plan.planName,
			priority: match.priority,
			emiMinor: match.emiMinor,
			suggestedAmountMinor: match.suggestedAmountMinor,
			affordabilityRatio: match.affordabilityRatio,
			interestRatePct: match.interestRatePct,
			tenorMonths: match.tenorMonths,
		})),
	};

	const advice = await aiComplete(c.env, {
		system: ADVICE_SYSTEM_PROMPT,
		user: `Shop data (all money in minor units, 1 unit = 1/100 of the major unit):\n${JSON.stringify(context, null, 2)}\n\n${input.message ? `Owner asks: ${input.message}` : "Give the owner one concrete next step to improve their access to finance."}`,
		maxTokens: 2048,
	});

	return c.json({
		advice,
		planIds: matchResult.matches.map((match) => match.plan.id),
		capacity: matchResult.capacity,
		monthlyRevenueMinor: matchResult.monthlyRevenueMinor,
		context,
	});
});

/* -------------------------------------------------------------------------- */
/* POST /api/ai/parse-sms                                                      */
/* -------------------------------------------------------------------------- */

/**
 * Runs the two-tier parser on a single message without persisting anything.
 *
 * This is the endpoint the demo uses to prove the parser works on an arbitrary
 * pasted SMS, and it is what the Flutter app can call to preview a message
 * before syncing the whole inbox.
 */
aiRoutes.post("/parse-sms", async (c) => {
	const input = await parseJsonBody(c, parseSmsSchema);

	const outcome = await parseSms(c.env, { sender: input.sender, body: input.body });

	return c.json({
		...outcome,
		// Lets the demo narrate which tier handled the message.
		tier: outcome.parseSource === "regex" ? 1 : outcome.parseSource === "llm" ? 2 : 0,
		moneyFormat: "amountMinor is an integer in minor units (1 BDT = 100 minor units)",
	});
});

/**
 * Availability probe. Reports *whether* an AI provider exists, never which one
 * and never any part of a key.
 */
aiRoutes.get("/status", (c) =>
	c.json({
		available: hasAnyAiProvider(c.env),
		hint: hasAnyAiProvider(c.env)
			? "An AI provider is configured."
			: "Set GEMINI_API_KEY (or GROQ_API_KEY / OPENROUTER_API_KEY) with `wrangler secret put`.",
	}),
);
