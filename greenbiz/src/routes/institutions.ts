import { Hono } from "hono";
import { asc, eq, sql } from "drizzle-orm";
import { financialInstitutions, financialServicePlans } from "../db/schema";
import type { AppBindings } from "../lib/context";

/**
 * Public financial-institution directory.
 *
 * Like the plan directory, this is public information and contains no user data.
 */
export const institutionRoutes = new Hono<AppBindings>();

institutionRoutes.get("/", async (c) => {
	const db = c.get("db");

	// A correlated subquery counts active plans without pulling every plan row
	// across the wire just to call `.length` on it.
	const rows = await db
		.select({
			institution: financialInstitutions,
			activePlanCount: sql<number>`(
				select count(*) from ${financialServicePlans}
				where ${financialServicePlans.institutionId} = ${financialInstitutions.id}
				  and ${financialServicePlans.isActive} = 1
			)`,
		})
		.from(financialInstitutions)
		.where(eq(financialInstitutions.isActive, true))
		.orderBy(asc(financialInstitutions.name));

	return c.json({
		institutions: rows.map((row) => ({
			...row.institution,
			activePlanCount: Number(row.activePlanCount),
		})),
	});
});
