import { Hono } from "hono";
import { and, asc, eq, gte, isNull, lte, or, type SQL } from "drizzle-orm";
import { z } from "zod";
import { financialInstitutions, financialServicePlans } from "../db/schema";
import type { AppBindings } from "../lib/context";
import { notFound } from "../lib/errors";
import { paginationQuery } from "../lib/schemas";
import { idParam, parseParams, parseQuery } from "../lib/validate";

/**
 * Public plan directory.
 *
 * No authentication: the catalogue of financial products is public information,
 * and requiring a login would stop a prospective user from seeing what is
 * available before they sign up. It contains zero user data.
 */
export const planRoutes = new Hono<AppBindings>();

const planQuery = paginationQuery.extend({
	serviceType: z
		.enum(["loan", "insurance", "savings", "current_account", "working_capital"])
		.optional(),
	/** Minor units. Returns plans able to serve this amount. */
	minAmount: z.coerce.number().int().nonnegative().optional(),
	maxAmount: z.coerce.number().int().nonnegative().optional(),
	institutionId: z.uuid().optional(),
});

/* -------------------------------------------------------------------------- */
/* GET /api/plans                                                              */
/* -------------------------------------------------------------------------- */

planRoutes.get("/plans", async (c) => {
	const { limit, offset, serviceType, minAmount, maxAmount, institutionId } = parseQuery(c, planQuery);
	const db = c.get("db");

	const filters: SQL[] = [eq(financialServicePlans.isActive, true)];

	if (serviceType) filters.push(eq(financialServicePlans.serviceType, serviceType));
	if (institutionId) filters.push(eq(financialServicePlans.institutionId, institutionId));

	// Amount filter is an *overlap* test, not containment: a plan is relevant if
	// its band intersects the caller's window. A shop asking for 5,000-500,000
	// should still see a 10,000-1,000,000 plan.
	//
	// A NULL bound means "no limit stated by the provider", which matches any
	// request rather than being excluded for lack of a number.
	if (minAmount !== undefined) {
		filters.push(
			or(
				isNull(financialServicePlans.maxAmountMinor),
				gte(financialServicePlans.maxAmountMinor, minAmount),
			)!,
		);
	}
	if (maxAmount !== undefined) {
		filters.push(
			or(
				isNull(financialServicePlans.minAmountMinor),
				lte(financialServicePlans.minAmountMinor, maxAmount),
			)!,
		);
	}

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
		.where(and(...filters))
		.orderBy(asc(financialServicePlans.serviceType), asc(financialServicePlans.planName))
		.limit(limit)
		.offset(offset);

	return c.json({
		plans: rows.map((row) => ({
			...row.plan,
			institutionName: row.institutionName,
			institutionType: row.institutionType,
			eligibility: parseJsonColumn(row.plan.eligibilityCriteria),
			fees: parseJsonColumn(row.plan.feesDetails),
		})),
		limit,
		offset,
	});
});

/* -------------------------------------------------------------------------- */
/* GET /api/plans/:id                                                          */
/* -------------------------------------------------------------------------- */

planRoutes.get("/plans/:id", async (c) => {
	const { id } = parseParams(c, idParam("id"));
	const db = c.get("db");

	const [row] = await db
		.select({
			plan: financialServicePlans,
			institution: financialInstitutions,
		})
		.from(financialServicePlans)
		.innerJoin(
			financialInstitutions,
			eq(financialServicePlans.institutionId, financialInstitutions.id),
		)
		.where(eq(financialServicePlans.id, id))
		.limit(1);

	if (!row) throw notFound("Plan not found");

	return c.json({
		plan: {
			...row.plan,
			eligibility: parseJsonColumn(row.plan.eligibilityCriteria),
			fees: parseJsonColumn(row.plan.feesDetails),
			institution: row.institution,
		},
	});
});

/**
 * TEXT columns holding JSON are decoded leniently: a malformed value yields
 * null rather than a 500, because a single bad catalogue row must not take the
 * whole directory down.
 */
function parseJsonColumn(value: string | null): unknown {
	if (!value) return null;
	try {
		return JSON.parse(value);
	} catch {
		return null;
	}
}
