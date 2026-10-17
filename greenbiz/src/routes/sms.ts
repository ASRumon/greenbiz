import { Hono } from "hono";
import { and, desc, eq } from "drizzle-orm";
import { z } from "zod";
import { shops, smsMessages } from "../db/schema";
import type { AppBindings } from "../lib/context";
import { currentUserId } from "../lib/context";
import { notFound } from "../lib/errors";
import { paginationQuery, timestampMs } from "../lib/schemas";
import { idParam, parseJsonBody, parseParams, parseQuery } from "../lib/validate";
import { requireAuth } from "../middleware/auth";
import { recomputeCreditProfile } from "../services/creditScore";
import { ingestSms, reparseSms, type IngestResult } from "../services/smsIngest";
import { requireOwnedShop } from "../services/shopAccess";

export const smsRoutes = new Hono<AppBindings>();

// Per-route guards: this router is mounted at /api, so a wildcard middleware
// would leak onto the public routes mounted at the same prefix.

/**
 * Upper bound on one batch. The Flutter client filters the device inbox to
 * known mobile-money senders over 90 days before uploading, so a real batch is
 * tens of messages; this cap stops a malformed client from queueing thousands
 * of LLM calls inside one request.
 */
const MAX_BATCH_MESSAGES = 500;

/** Parallel ingest width. Keeps a large batch fast without stampeding D1. */
const INGEST_CONCURRENCY = 20;

const bulkSchema = z.object({
	messages: z
		.array(
			z.object({
				sender: z.string().trim().min(1, "sender is required").max(64),
				body: z.string().min(1, "body is required").max(2000),
				receivedAt: timestampMs,
			}),
		)
		.min(1, "messages cannot be empty")
		.max(MAX_BATCH_MESSAGES, `At most ${MAX_BATCH_MESSAGES} messages per batch`),
});

const listQuery = paginationQuery.extend({
	parseStatus: z.enum(["pending", "parsed", "failed"]).optional(),
});

/* -------------------------------------------------------------------------- */
/* POST /api/shops/:shopId/sms/bulk                                            */
/* -------------------------------------------------------------------------- */

smsRoutes.post("/shops/:shopId/sms/bulk", requireAuth, async (c) => {
	const { shopId } = parseParams(c, idParam("shopId"));
	const { messages } = await parseJsonBody(c, bulkSchema);
	const db = c.get("db");
	const userId = currentUserId(c);

	await requireOwnedShop(db, shopId, userId);

	const results: IngestResult[] = [];

	// Chunked `Promise.all`: D1 handles a handful of concurrent statements well,
	// and the alternative - one round trip per message - makes a 90-day inbox
	// sync feel broken.
	for (let index = 0; index < messages.length; index += INGEST_CONCURRENCY) {
		const chunk = messages.slice(index, index + INGEST_CONCURRENCY);
		const chunkResults = await Promise.all(
			chunk.map((message) =>
				ingestSms(c.env, db, shopId, {
					sender: message.sender,
					body: message.body,
					receivedAt: message.receivedAt,
				}),
			),
		);
		results.push(...chunkResults);
	}

	// The score depends on the transactions just written, so refresh it here
	// rather than making the client remember to call recompute. Without this the
	// Finance tab shows a stale score immediately after the flagship flow.
	let score: number | null = null;
	let recomputeFailed = false;
	try {
		const profile = await recomputeCreditProfile(db, shopId);
		score = profile.score;
	} catch (error) {
		// Ingestion succeeded; failing the whole request over a derived value
		// would force a pointless re-upload.
		recomputeFailed = true;
		console.error("Credit recompute after SMS ingest failed:", error instanceof Error ? error.message : error);
	}

	const summary = {
		received: messages.length,
		inserted: results.filter((r) => r.outcome === "inserted").length,
		duplicates: results.filter((r) => r.outcome === "duplicate").length,
		notPayment: results.filter((r) => r.outcome === "not_payment").length,
		parsed: results.filter((r) => r.parseStatus === "parsed").length,
		pending: results.filter((r) => r.parseStatus === "pending").length,
		failed: results.filter((r) => r.parseStatus === "failed").length,
		bySource: {
			regex: results.filter((r) => r.parseSource === "regex").length,
			llm: results.filter((r) => r.parseSource === "llm").length,
		},
		transactionsCreated: results.filter((r) => r.transactionId !== null).length,
		score,
		recomputeFailed,
	};

	return c.json({ summary, results });
});

/* -------------------------------------------------------------------------- */
/* GET /api/shops/:shopId/sms                                                  */
/* -------------------------------------------------------------------------- */

smsRoutes.get("/shops/:shopId/sms", requireAuth, async (c) => {
	const { shopId } = parseParams(c, idParam("shopId"));
	const { limit, offset, parseStatus } = parseQuery(c, listQuery);
	const db = c.get("db");

	await requireOwnedShop(db, shopId, currentUserId(c));

	const filters = [eq(smsMessages.shopId, shopId)];
	if (parseStatus) filters.push(eq(smsMessages.parseStatus, parseStatus));

	const rows = await db
		.select()
		.from(smsMessages)
		.where(and(...filters))
		.orderBy(desc(smsMessages.receivedAt))
		.limit(limit)
		.offset(offset);

	return c.json({ smsMessages: rows, limit, offset });
});

/* -------------------------------------------------------------------------- */
/* POST /api/sms/:id/reparse                                                   */
/* -------------------------------------------------------------------------- */

smsRoutes.post("/sms/:id/reparse", requireAuth, async (c) => {
	const { id } = parseParams(c, idParam("id"));
	const db = c.get("db");
	const userId = currentUserId(c);

	// Ownership is checked with a join onto shops: an SMS id alone must never be
	// enough to act on someone else's data.
	const [row] = await db
		.select({ message: smsMessages })
		.from(smsMessages)
		.innerJoin(shops, eq(smsMessages.shopId, shops.id))
		.where(and(eq(smsMessages.id, id), eq(shops.ownerId, userId)))
		.limit(1);

	if (!row) throw notFound("SMS message not found");

	const result = await reparseSms(c.env, db, row.message);

	let score: number | null = null;
	if (result.parseStatus === "parsed") {
		const profile = await recomputeCreditProfile(db, row.message.shopId);
		score = profile.score;
	}

	return c.json({ result, score });
});
