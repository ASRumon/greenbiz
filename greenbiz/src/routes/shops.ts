import { Hono } from "hono";
import { and, asc, eq } from "drizzle-orm";
import { z } from "zod";
import { creditProfiles, loanApplications, products, shops, smsMessages, transactions } from "../db/schema";
import type { AppBindings } from "../lib/context";
import { currentUserId } from "../lib/context";
import { notFound } from "../lib/errors";
import { optionalText } from "../lib/schemas";
import { idParam, parseJsonBody, parseParams } from "../lib/validate";
import { requireAuth } from "../middleware/auth";
import { requireOwnedShop } from "../services/shopAccess";

export const shopRoutes = new Hono<AppBindings>();

shopRoutes.use("*", requireAuth);

/* -------------------------------------------------------------------------- */
/* Schemas                                                                     */
/* -------------------------------------------------------------------------- */

const createShopSchema = z.object({
	shopName: z.string().trim().min(1, "Shop name is required").max(120),
	businessType: optionalText(60),
	phone: optionalText(30),
	address: optionalText(240),
});

const updateShopSchema = z
	.object({
		shopName: z.string().trim().min(1, "Shop name cannot be empty").max(120).optional(),
		businessType: optionalText(60),
		phone: optionalText(30),
		address: optionalText(240),
	})
	.refine((value) => Object.keys(value).length > 0, {
		message: "Provide at least one field to update",
	});

/* -------------------------------------------------------------------------- */
/* GET /api/shops                                                              */
/* -------------------------------------------------------------------------- */

shopRoutes.get("/", async (c) => {
	const db = c.get("db");
	const rows = await db
		.select()
		.from(shops)
		.where(eq(shops.ownerId, currentUserId(c)))
		.orderBy(asc(shops.createdAt));

	return c.json({ shops: rows });
});

/* -------------------------------------------------------------------------- */
/* POST /api/shops                                                             */
/* -------------------------------------------------------------------------- */

shopRoutes.post("/", async (c) => {
	const input = await parseJsonBody(c, createShopSchema);
	const db = c.get("db");

	const shop = {
		id: crypto.randomUUID(),
		ownerId: currentUserId(c),
		shopName: input.shopName,
		businessType: input.businessType ?? null,
		phone: input.phone ?? null,
		address: input.address ?? null,
		createdAt: Date.now(),
	};

	await db.insert(shops).values(shop);
	return c.json({ shop }, 201);
});

/* -------------------------------------------------------------------------- */
/* GET /api/shops/:id                                                          */
/* -------------------------------------------------------------------------- */

shopRoutes.get("/:id", async (c) => {
	const { id } = parseParams(c, idParam("id"));
	const db = c.get("db");
	const shop = await requireOwnedShop(db, id, currentUserId(c));

	return c.json({ shop });
});

/* -------------------------------------------------------------------------- */
/* PATCH /api/shops/:id                                                        */
/* -------------------------------------------------------------------------- */

shopRoutes.patch("/:id", async (c) => {
	const { id } = parseParams(c, idParam("id"));
	const input = await parseJsonBody(c, updateShopSchema);
	const db = c.get("db");
	const userId = currentUserId(c);

	await requireOwnedShop(db, id, userId);

	await db
		.update(shops)
		.set({
			...(input.shopName === undefined ? {} : { shopName: input.shopName }),
			...(input.businessType === undefined ? {} : { businessType: input.businessType }),
			...(input.phone === undefined ? {} : { phone: input.phone }),
			...(input.address === undefined ? {} : { address: input.address }),
		})
		.where(and(eq(shops.id, id), eq(shops.ownerId, userId)));

	const updated = await requireOwnedShop(db, id, userId);
	return c.json({ shop: updated });
});

/* -------------------------------------------------------------------------- */
/* DELETE /api/shops/:id                                                       */
/* -------------------------------------------------------------------------- */

shopRoutes.delete("/:id", async (c) => {
	const { id } = parseParams(c, idParam("id"));
	const db = c.get("db");
	const userId = currentUserId(c);

	await requireOwnedShop(db, id, userId);

	// Delete children explicitly rather than relying on ON DELETE CASCADE:
	// foreign-key enforcement is a per-connection pragma, and a silent failure
	// here would orphan inventory and SMS rows forever.
	await db.batch([
		db.delete(transactions).where(eq(transactions.shopId, id)),
		db.delete(smsMessages).where(eq(smsMessages.shopId, id)),
		db.delete(products).where(eq(products.shopId, id)),
		db.delete(creditProfiles).where(eq(creditProfiles.shopId, id)),
		db.delete(loanApplications).where(eq(loanApplications.shopId, id)),
		db.delete(shops).where(and(eq(shops.id, id), eq(shops.ownerId, userId))),
	]);

	// Confirm it is actually gone; a 200 for a no-op delete is a lie.
	const [stillThere] = await db.select({ id: shops.id }).from(shops).where(eq(shops.id, id)).limit(1);
	if (stillThere) throw notFound("Shop could not be deleted");

	return c.json({ deleted: true, id });
});
