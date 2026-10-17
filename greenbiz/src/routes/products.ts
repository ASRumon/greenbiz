import { Hono } from "hono";
import { and, asc, eq, inArray } from "drizzle-orm";
import { z } from "zod";
import { products, shops } from "../db/schema";
import type { AppBindings } from "../lib/context";
import { currentUserId } from "../lib/context";
import { AppError } from "../lib/errors";
import {
	minorUnits,
	optionalMinorUnits,
	optionalQuantity,
	paginationQuery,
	quantity,
	uuid,
} from "../lib/schemas";
import { idParam, parseJsonBody, parseParams, parseQuery } from "../lib/validate";
import { requireAuth } from "../middleware/auth";
import { requireOwnedProduct, requireOwnedShop } from "../services/shopAccess";

/**
 * Mounted at `/api`, because this module serves two path families:
 *   /api/shops/:shopId/products  (create + list, scoped by shop)
 *   /api/products/:id            (update + delete, scoped by product)
 */
export const productRoutes = new Hono<AppBindings>();

// NOTE: there is deliberately no `use("*", requireAuth)` here. This router is
// mounted at /api, so a wildcard middleware would also guard every sibling
// route under /api — including the deliberately public /api/plans and
// /api/institutions. Each route below declares its own guard instead.

/* -------------------------------------------------------------------------- */
/* Schemas                                                                     */
/* -------------------------------------------------------------------------- */

const shopIdParam = z.object({ shopId: z.uuid("shopId must be a valid UUID") });

const createProductSchema = z.object({
	/** Client-generated id, so an offline write can be retried safely. */
	id: uuid.optional(),
	productName: z.string().trim().min(1, "Product name is required").max(120),
	unit: z.string().trim().min(1, "Unit is required").max(20),
	unitPriceMinor: minorUnits,
	stockQuantity: quantity.default(0),
});

const updateProductSchema = z
	.object({
		productName: z.string().trim().min(1, "Product name cannot be empty").max(120).optional(),
		unit: z.string().trim().min(1, "Unit cannot be empty").max(20).optional(),
		unitPriceMinor: optionalMinorUnits,
		stockQuantity: optionalQuantity,
	})
	.refine((value) => Object.keys(value).length > 0, {
		message: "Provide at least one field to update",
	});

/* -------------------------------------------------------------------------- */
/* GET /api/shops/:shopId/products                                             */
/* -------------------------------------------------------------------------- */

productRoutes.get("/shops/:shopId/products", requireAuth, async (c) => {
	const { shopId } = parseParams(c, shopIdParam);
	const { limit, offset } = parseQuery(c, paginationQuery);
	const db = c.get("db");

	await requireOwnedShop(db, shopId, currentUserId(c));

	const rows = await db
		.select()
		.from(products)
		.where(eq(products.shopId, shopId))
		.orderBy(asc(products.productName))
		.limit(limit)
		.offset(offset);

	return c.json({ products: rows, limit, offset });
});

/* -------------------------------------------------------------------------- */
/* POST /api/shops/:shopId/products                                            */
/* -------------------------------------------------------------------------- */

productRoutes.post("/shops/:shopId/products", requireAuth, async (c) => {
	const { shopId } = parseParams(c, shopIdParam);
	const input = await parseJsonBody(c, createProductSchema);
	const db = c.get("db");

	await requireOwnedShop(db, shopId, currentUserId(c));

	if (input.id) {
		const [existing] = await db
			.select()
			.from(products)
			.where(eq(products.id, input.id))
			.limit(1);
		if (existing) {
			// Offline retry after the first attempt succeeded but the response was lost.
			if (existing.shopId !== shopId) {
				throw new AppError("CONFLICT", "Product id is already in use");
			}
			return c.json({ product: existing });
		}
	}

	const product = {
		id: input.id ?? crypto.randomUUID(),
		shopId,
		productName: input.productName,
		unit: input.unit,
		unitPriceMinor: input.unitPriceMinor,
		stockQuantity: input.stockQuantity,
		createdAt: Date.now(),
	};

	await db.insert(products).values(product);
	return c.json({ product }, 201);
});

/* -------------------------------------------------------------------------- */
/* PATCH /api/products/:id                                                     */
/* -------------------------------------------------------------------------- */

productRoutes.patch("/products/:id", requireAuth, async (c) => {
	const { id } = parseParams(c, idParam("id"));
	const input = await parseJsonBody(c, updateProductSchema);
	const db = c.get("db");
	const userId = currentUserId(c);

	await requireOwnedProduct(db, id, userId);

	await db
		.update(products)
		.set({
			...(input.productName === undefined ? {} : { productName: input.productName }),
			...(input.unit === undefined ? {} : { unit: input.unit }),
			...(input.unitPriceMinor === undefined ? {} : { unitPriceMinor: input.unitPriceMinor }),
			...(input.stockQuantity === undefined ? {} : { stockQuantity: input.stockQuantity }),
		})
		.where(eq(products.id, id));

	const { product } = await requireOwnedProduct(db, id, userId);
	return c.json({ product });
});

/* -------------------------------------------------------------------------- */
/* DELETE /api/products/:id                                                    */
/* -------------------------------------------------------------------------- */

productRoutes.delete("/products/:id", requireAuth, async (c) => {
	const { id } = parseParams(c, idParam("id"));
	const db = c.get("db");
	const userId = currentUserId(c);

	await requireOwnedProduct(db, id, userId);

	// Ownership is enforced inside the DELETE itself via a subquery, not just by
	// the guard above: the `WHERE` can only ever match a shop this user owns.
	const ownedShopIds = db.select({ id: shops.id }).from(shops).where(eq(shops.ownerId, userId));

	await db.delete(products).where(and(eq(products.id, id), inArray(products.shopId, ownedShopIds)));

	const remaining = await db
		.select({ id: products.id })
		.from(products)
		.where(eq(products.id, id))
		.limit(1);

	if (remaining.length > 0) {
		throw new AppError("INTERNAL", "Product could not be deleted");
	}

	return c.json({ deleted: true, id });
});
