import { Hono } from "hono";
import { and, desc, eq, getTableColumns, gte, inArray, lte } from "drizzle-orm";
import { z } from "zod";
import { shops, smsMessages, transactions } from "../db/schema";
import type { Database } from "../db/client";
import type { AppBindings } from "../lib/context";
import { currentUserId } from "../lib/context";
import { AppError, conflict, notFound } from "../lib/errors";
import {
	currencyCode,
	minorUnits,
	optionalMinorUnits,
	optionalText,
	paginationQuery,
	paymentDirection,
	paymentMethod,
	timestampMs,
	uuid,
} from "../lib/schemas";
import { idParam, parseJsonBody, parseParams, parseQuery } from "../lib/validate";
import { requireAuth } from "../middleware/auth";
import { recomputeCreditProfile } from "../services/creditScore";
import { requireOwnedShop } from "../services/shopAccess";
import { resolveShopCurrency } from "../services/smsIngest";

/**
 * Mounted at `/api`:
 *   /api/shops/:shopId/transactions
 *   /api/transactions/:id
 */
export const transactionRoutes = new Hono<AppBindings>();

// Per-route guards: this router is mounted at /api, so a wildcard middleware
// would leak onto the public routes mounted at the same prefix.

/* -------------------------------------------------------------------------- */
/* Schemas                                                                     */
/* -------------------------------------------------------------------------- */

const shopIdParam = z.object({ shopId: z.uuid("shopId must be a valid UUID") });

const rangeQuery = paginationQuery.extend({
	/**
	 * Reports need the whole range in one page. The shared pagination cap is
	 * 500, which silently truncated a year of history; this route is the one
	 * place that legitimately asks for more.
	 */
	limit: z.coerce.number().int().min(1).max(5000).default(100),
	/** Inclusive lower bound, Unix ms. */
	from: z.coerce.number().int().nonnegative().optional(),
	/** Inclusive upper bound, Unix ms. */
	to: z.coerce.number().int().nonnegative().optional(),
	direction: paymentDirection.optional(),
	/** "true" returns only business rows (used by the cash-flow card). */
	businessOnly: z.enum(["true", "false"]).optional(),
});

const createTransactionSchema = z.object({
	/** Client-generated id, so an offline write can be retried safely. */
	id: uuid.optional(),
	direction: paymentDirection,
	amountMinor: minorUnits.refine((value) => value > 0, "Amount must be greater than zero"),
	currency: currencyCode.optional(),
	counterparty: optionalText(120),
	reference: optionalText(64),
	occurredAt: timestampMs.optional(),
	note: optionalText(240),
	isBusiness: z.boolean().optional(),
	paymentMethod: paymentMethod.optional(),
});

const updateTransactionSchema = z
	.object({
		direction: paymentDirection.optional(),
		amountMinor: optionalMinorUnits,
		currency: currencyCode.optional(),
		counterparty: optionalText(120),
		reference: optionalText(64),
		occurredAt: timestampMs.optional(),
		note: optionalText(240),
		isBusiness: z.boolean().optional(),
		paymentMethod: paymentMethod.optional(),
	})
	.refine((value) => Object.keys(value).length > 0, {
		message: "Provide at least one field to update",
	});

/** Recomputes the score after a ledger change, without failing the write. */
async function refreshScore(db: Database, shopId: string) {
	try {
		const profile = await recomputeCreditProfile(db, shopId);
		return profile.score;
	} catch (error) {
		console.error(
			"Credit recompute after transaction write failed:",
			error instanceof Error ? error.message : error,
		);
		return null;
	}
}

/* -------------------------------------------------------------------------- */
/* GET /api/shops/:shopId/transactions                                         */
/* -------------------------------------------------------------------------- */

transactionRoutes.get("/shops/:shopId/transactions", requireAuth, async (c) => {
	const { shopId } = parseParams(c, shopIdParam);
	const { limit, offset, from, to, direction, businessOnly } = parseQuery(c, rangeQuery);
	const db = c.get("db");

	await requireOwnedShop(db, shopId, currentUserId(c));

	const filters = [eq(transactions.shopId, shopId)];
	if (from !== undefined) filters.push(gte(transactions.occurredAt, from));
	if (to !== undefined) filters.push(lte(transactions.occurredAt, to));
	if (direction) filters.push(eq(transactions.direction, direction));
	if (businessOnly === "true") filters.push(eq(transactions.isBusiness, true));

	const rows = await db
		.select({
			...getTableColumns(transactions),
			// The raw confirmation, joined in so the Payments screen can show
			// exactly what the provider sent. Null for manual rows.
			smsSender: smsMessages.sender,
			smsBody: smsMessages.body,
		})
		.from(transactions)
		.leftJoin(smsMessages, eq(transactions.smsId, smsMessages.id))
		.where(and(...filters))
		.orderBy(desc(transactions.occurredAt))
		.limit(limit)
		.offset(offset);

	// Totals are computed over the filtered range, so the client does not have
	// to download every row to render a cash-flow card.
	const totalInMinor = rows
		.filter((row) => row.direction === "in")
		.reduce((sum, row) => sum + row.amountMinor, 0);
	const totalOutMinor = rows
		.filter((row) => row.direction === "out")
		.reduce((sum, row) => sum + row.amountMinor, 0);

	return c.json({
		transactions: rows,
		totals: { inMinor: totalInMinor, outMinor: totalOutMinor, netMinor: totalInMinor - totalOutMinor },
		limit,
		offset,
	});
});

/* -------------------------------------------------------------------------- */
/* POST /api/shops/:shopId/transactions                                        */
/* -------------------------------------------------------------------------- */

transactionRoutes.post("/shops/:shopId/transactions", requireAuth, async (c) => {
	const { shopId } = parseParams(c, shopIdParam);
	const input = await parseJsonBody(c, createTransactionSchema);
	const db = c.get("db");

	await requireOwnedShop(db, shopId, currentUserId(c));

	// Offline retries reuse the client's id. If that id already exists, the
	// write succeeded before the network dropped, so return it instead of
	// double-booking the money.
	if (input.id) {
		const [existing] = await db
			.select()
			.from(transactions)
			.where(eq(transactions.id, input.id))
			.limit(1);
		if (existing) {
			if (existing.shopId !== shopId) throw conflict("Transaction id is already in use");
			return c.json({ transaction: existing, score: null });
		}
	}

	const transaction = {
		id: input.id ?? crypto.randomUUID(),
		shopId,
		smsId: null,
		direction: input.direction,
		amountMinor: input.amountMinor,
		currency: input.currency ?? (await resolveShopCurrency(db, shopId)),
		counterparty: input.counterparty ?? null,
		reference: input.reference ?? null,
		occurredAt: input.occurredAt ?? Date.now(),
		note: input.note ?? null,
		isBusiness: input.isBusiness ?? true,
		paymentMethod: input.paymentMethod ?? null,
		createdAt: Date.now(),
	};

	const [created] = await db.insert(transactions).values(transaction).returning();
	if (!created) throw new AppError("INTERNAL", "Transaction could not be saved");

	const score = await refreshScore(db, shopId);
	return c.json({ transaction: created, score }, 201);
});

/* -------------------------------------------------------------------------- */
/* PATCH /api/transactions/:id                                                 */
/* -------------------------------------------------------------------------- */

transactionRoutes.patch("/transactions/:id", requireAuth, async (c) => {
	const { id } = parseParams(c, idParam("id"));
	const input = await parseJsonBody(c, updateTransactionSchema);
	const db = c.get("db");
	const userId = currentUserId(c);

	const existing = await findOwnedTransaction(db, id, userId);

	const [updated] = await db
		.update(transactions)
		.set({
			...(input.direction === undefined ? {} : { direction: input.direction }),
			...(input.amountMinor === undefined ? {} : { amountMinor: input.amountMinor }),
			...(input.currency === undefined ? {} : { currency: input.currency }),
			...(input.counterparty === undefined ? {} : { counterparty: input.counterparty }),
			...(input.reference === undefined ? {} : { reference: input.reference }),
			...(input.occurredAt === undefined ? {} : { occurredAt: input.occurredAt }),
			...(input.note === undefined ? {} : { note: input.note }),
			...(input.isBusiness === undefined ? {} : { isBusiness: input.isBusiness }),
			...(input.paymentMethod === undefined ? {} : { paymentMethod: input.paymentMethod }),
		})
		.where(eq(transactions.id, id))
		.returning();

	if (!updated) throw notFound("Transaction not found");

	const score = await refreshScore(db, existing.shopId);
	return c.json({ transaction: updated, score });
});

/* -------------------------------------------------------------------------- */
/* DELETE /api/transactions/:id                                                */
/* -------------------------------------------------------------------------- */

transactionRoutes.delete("/transactions/:id", requireAuth, async (c) => {
	const { id } = parseParams(c, idParam("id"));
	const db = c.get("db");
	const userId = currentUserId(c);

	const existing = await findOwnedTransaction(db, id, userId);

	await db.delete(transactions).where(eq(transactions.id, id));

	const score = await refreshScore(db, existing.shopId);
	return c.json({ deleted: true, id, score });
});

/* -------------------------------------------------------------------------- */
/* Helpers                                                                     */
/* -------------------------------------------------------------------------- */

/**
 * Loads a transaction only if the caller owns the shop it belongs to.
 *
 * The `inArray(..., subquery)` form pushes the ownership rule into the query
 * itself rather than trusting a value fetched earlier in the request.
 */
async function findOwnedTransaction(
	db: Database,
	id: string,
	userId: string,
) {
	const ownedShopIds = db.select({ id: shops.id }).from(shops).where(eq(shops.ownerId, userId));

	const [row] = await db
		.select()
		.from(transactions)
		.where(and(eq(transactions.id, id), inArray(transactions.shopId, ownedShopIds)))
		.limit(1);

	if (!row) throw notFound("Transaction not found");
	return row;
}
