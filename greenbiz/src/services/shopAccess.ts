import { and, eq } from "drizzle-orm";
import type { Database } from "../db/client";
import { products, shops, type ShopRow } from "../db/schema";
import { notFound } from "../lib/errors";

/**
 * Ownership enforcement.
 *
 * Every shop-scoped route funnels through here, so "can this user touch this
 * row?" is answered in exactly one place instead of being re-derived (and
 * eventually forgotten) in each handler.
 *
 * Missing OR not-owned both return 404. Returning 403 for a shop that exists but
 * belongs to somebody else would confirm that the id is real, which is a free
 * enumeration oracle for a competitor or a scraper.
 */
export async function requireOwnedShop(
	db: Database,
	shopId: string,
	userId: string,
): Promise<ShopRow> {
	const [shop] = await db
		.select()
		.from(shops)
		.where(and(eq(shops.id, shopId), eq(shops.ownerId, userId)))
		.limit(1);

	if (!shop) throw notFound("Shop not found");
	return shop;
}

/**
 * Finds a product and verifies the caller owns the shop it belongs to.
 * Returns the product plus its shop id for callers that need to recompute
 * derived data afterwards.
 */
export async function requireOwnedProduct(
	db: Database,
	productId: string,
	userId: string,
): Promise<{ product: typeof products.$inferSelect }> {
	const [row] = await db
		.select()
		.from(products)
		.innerJoin(shops, eq(products.shopId, shops.id))
		.where(and(eq(products.id, productId), eq(shops.ownerId, userId)))
		.limit(1);

	if (!row) throw notFound("Product not found");
	return { product: row.products };
}
