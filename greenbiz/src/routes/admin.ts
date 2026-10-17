import { Hono } from "hono";
import { z } from "zod";
import { financialInstitutions, financialServicePlans } from "../db/schema";
import type { AppBindings } from "../lib/context";
import { chunkForInsert } from "../lib/d1Limits";
import { requireAdmin } from "../middleware/auth";
import planSeed from "../../seed/plans.json";
import institutionSeed from "../../seed/institutions.json";

export const adminRoutes = new Hono<AppBindings>();

adminRoutes.use("*", requireAdmin);

/** Column counts, used to size multi-row inserts against the D1 parameter cap. */
const INSTITUTION_COLUMNS = 8;
const PLAN_COLUMNS = 16;

/* -------------------------------------------------------------------------- */
/* Seed schemas                                                                */
/* -------------------------------------------------------------------------- */

/**
 * The seed JSON is bundled into the Worker, so it is validated at load time as
 * well as at request time. A malformed catalogue file fails loudly here instead
 * of writing half-valid rows into the directory.
 */
const institutionRowSchema = z.object({
	id: z.uuid(),
	name: z.string().min(1),
	institutionType: z.string().min(1),
	website: z.string().nullable(),
	description: z.string().nullable(),
	contactPhone: z.string().nullable(),
	isActive: z.boolean(),
});

const planRowSchema = z.object({
	id: z.uuid(),
	institutionId: z.uuid(),
	planName: z.string().min(1),
	serviceType: z.enum(["loan", "insurance", "savings", "current_account", "working_capital"]),
	description: z.string().nullable(),
	minAmountMinor: z.number().int().nullable(),
	maxAmountMinor: z.number().int().nullable(),
	interestRateMin: z.number().nullable(),
	interestRateMax: z.number().nullable(),
	durationMonths: z.number().int().nullable(),
	eligibilityCriteria: z.record(z.string(), z.unknown()).nullable(),
	feesDetails: z.record(z.string(), z.unknown()).nullable(),
	sourceUrl: z.string().nullable(),
	lastVerifiedAt: z.number().int().nullable(),
	isActive: z.boolean(),
});

/* -------------------------------------------------------------------------- */
/* POST /api/admin/seed                                                        */
/* -------------------------------------------------------------------------- */

/**
 * Loads the financial catalogue.
 *
 * Protected by ADMIN_TOKEN rather than by a user session: this writes
 * global (non-shop-scoped) public data, so no shop owner should be able to
 * trigger it, and it is safe to run from CI.
 *
 * Replaces the catalogue rather than merging into it, mirroring seed/seed.sql:
 * if a plan is removed from plans.json it should disappear from the directory,
 * not linger forever as an orphan row.
 */
adminRoutes.post("/seed", async (c) => {
	const db = c.get("db");

	const institutions = z.array(institutionRowSchema).parse(institutionSeed);
	const plans = z.array(planRowSchema).parse(planSeed);

	// Every plan references an institution, so plans must go first.
	await db.batch([
		db.delete(financialServicePlans),
		db.delete(financialInstitutions),
	]);

	const now = Date.now();

	// Chunked because D1 allows at most 100 bound parameters per statement:
	// 14 institutions x 8 columns = 112 would exceed it in one go.
	const institutionRows = institutions.map((row) => ({
		id: row.id,
		name: row.name,
		institutionType: row.institutionType,
		website: row.website,
		description: row.description,
		contactPhone: row.contactPhone,
		isActive: row.isActive,
		createdAt: now,
	}));

	for (const chunk of chunkForInsert(institutionRows, INSTITUTION_COLUMNS)) {
		await db.insert(financialInstitutions).values(chunk);
	}

	const planRows = plans.map((row) => ({
		id: row.id,
		institutionId: row.institutionId,
		planName: row.planName,
		serviceType: row.serviceType,
		description: row.description,
		minAmountMinor: row.minAmountMinor,
		maxAmountMinor: row.maxAmountMinor,
		interestRateMin: row.interestRateMin,
		interestRateMax: row.interestRateMax,
		durationMonths: row.durationMonths,
		eligibilityCriteria: row.eligibilityCriteria
			? JSON.stringify(row.eligibilityCriteria)
			: null,
		feesDetails: row.feesDetails ? JSON.stringify(row.feesDetails) : null,
		sourceUrl: row.sourceUrl,
		lastVerifiedAt: row.lastVerifiedAt,
		isActive: row.isActive,
		createdAt: now,
	}));

	for (const chunk of chunkForInsert(planRows, PLAN_COLUMNS)) {
		await db.insert(financialServicePlans).values(chunk);
	}

	return c.json({
		ok: true,
		institutions: institutions.length,
		plans: plans.length,
		seededAt: now,
	});
});
