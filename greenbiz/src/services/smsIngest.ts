import { and, desc, eq } from "drizzle-orm";
import type { Database } from "../db/client";
import { shops, smsMessages, transactions, type SmsMessageRow } from "../db/schema";
import { parseSms, type ParseOutcome } from "./smsParser";

/**
 * SMS ingestion.
 *
 * Shared by bulk sync (`POST /shops/:id/sms/bulk`) and reparse
 * (`POST /sms/:id/reparse`) so both paths apply identical rules about when a
 * parsed message is allowed to become a booked transaction.
 */

export type SupportedCurrency = "BDT" | "INR";

/**
 * Currency for a transaction whose SMS does not state one.
 *
 * Shops has no currency column (the schema in the design doc does not have
 * one), so it is inferred from the shop's own history: the most recent
 * transaction's currency. Falls back to BDT, matching the Bangladesh-first
 * launch market. This means an Indian shop corrects itself as soon as one INR
 * transaction exists, instead of every row defaulting to BDT forever.
 */
export async function resolveShopCurrency(
	db: Database,
	shopId: string,
): Promise<SupportedCurrency> {
	const [row] = await db
		.select({ currency: transactions.currency })
		.from(transactions)
		.where(eq(transactions.shopId, shopId))
		.orderBy(desc(transactions.occurredAt))
		.limit(1);

	return row?.currency === "INR" ? "INR" : "BDT";
}

export interface SmsIngestInput {
	sender: string;
	body: string;
	receivedAt: number;
}

export type IngestOutcome =
	/** New SMS row; a transaction was created if it parsed. */
	| "inserted"
	/** Already present (same shop, sender, body, timestamp) - nothing written. */
	| "duplicate"
	/** Stored, but the body is not a payment message. */
	| "not_payment";

export interface IngestResult {
	smsId: string;
	outcome: IngestOutcome;
	provider: string;
	parseStatus: "pending" | "parsed" | "failed";
	parseSource: "regex" | "llm" | null;
	transactionId: string | null;
	detail?: string;
}

/**
 * Writes one SMS and, when it parses confidently, the matching transaction.
 *
 * Idempotency comes from the unique index on
 * `(shop_id, sender, body, received_at)`: the insert is `ON CONFLICT DO
 * NOTHING` with `RETURNING`, so an empty result *is* the duplicate signal. That
 * is one round trip instead of a SELECT followed by an INSERT, and it is
 * race-free - two concurrent uploads of the same inbox cannot both win.
 */
export async function ingestSms(
	env: Env,
	db: Database,
	shopId: string,
	input: SmsIngestInput,
): Promise<IngestResult> {
	const outcome: ParseOutcome = await parseSms(env, {
		sender: input.sender,
		body: input.body,
	});

	const now = Date.now();
	const candidateId = crypto.randomUUID();

	const inserted = await db
		.insert(smsMessages)
		.values({
			id: candidateId,
			shopId,
			sender: input.sender,
			body: input.body,
			receivedAt: input.receivedAt,
			provider: outcome.provider,
			parseStatus: outcome.parseStatus,
			parseError: outcome.parseError ?? null,
			parseSource: outcome.parseSource,
			rawExtract: serializeExtract(outcome),
			createdAt: now,
		})
		.onConflictDoNothing({
			target: [smsMessages.shopId, smsMessages.sender, smsMessages.body, smsMessages.receivedAt],
		})
		.returning({ id: smsMessages.id });

	if (inserted.length === 0) {
		// Already ingested in a previous sync. Look the row up by the same
		// four-column key so the caller gets the *existing* id, not an
		// arbitrary neighbouring row.
		const [existing] = await db
			.select({ id: smsMessages.id })
			.from(smsMessages)
			.where(
				and(
					eq(smsMessages.shopId, shopId),
					eq(smsMessages.sender, input.sender),
					eq(smsMessages.body, input.body),
					eq(smsMessages.receivedAt, input.receivedAt),
				),
			)
			.limit(1);

		return {
			smsId: existing?.id ?? candidateId,
			outcome: "duplicate",
			provider: outcome.provider,
			parseStatus: outcome.parseStatus,
			parseSource: outcome.parseSource,
			transactionId: null,
			detail: "already synced",
		};
	}

	const smsId = inserted[0]?.id ?? candidateId;

	const result: IngestResult = {
		smsId,
		outcome: outcome.parseStatus === "failed" ? "not_payment" : "inserted",
		provider: outcome.provider,
		parseStatus: outcome.parseStatus,
		parseSource: outcome.parseSource,
		transactionId: null,
		...(outcome.detail === undefined ? {} : { detail: outcome.detail }),
	};

	if (outcome.parseStatus !== "parsed" || !outcome.extract) {
		return result;
	}

	result.transactionId = await bookTransaction(db, {
		shopId,
		smsId,
		direction: outcome.extract.direction,
		amountMinor: outcome.extract.amountMinor,
		currency: outcome.currency,
		counterparty: outcome.extract.counterparty,
		reference: outcome.extract.reference,
		paymentMethod: outcome.provider === "unknown" ? undefined : outcome.provider,
		occurredAt: input.receivedAt,
		note: `Imported from ${outcome.provider} SMS`,
	});

	return result;
}

/**
 * Creates the transaction for a parsed SMS.
 *
 * `ON CONFLICT DO NOTHING` on the `sms_id` unique index makes this safe to call
 * repeatedly: reparsing a message can never double-book the money.
 */
async function bookTransaction(
	db: Database,
	input: {
		shopId: string;
		smsId: string;
		direction: "in" | "out";
		amountMinor: number;
		currency: SupportedCurrency | null;
		counterparty?: string;
		reference?: string;
		paymentMethod?: "bkash" | "nagad" | "rocket" | "upay" | "upi";
		occurredAt: number;
		note: string;
	},
): Promise<string | null> {
	const currency = input.currency ?? (await resolveShopCurrency(db, input.shopId));
	const id = crypto.randomUUID();

	const created = await db
		.insert(transactions)
		.values({
			id,
			shopId: input.shopId,
			smsId: input.smsId,
			direction: input.direction,
			amountMinor: input.amountMinor,
			currency,
			counterparty: input.counterparty ?? null,
			reference: input.reference ?? null,
			occurredAt: input.occurredAt,
			note: input.note,
			paymentMethod: input.paymentMethod ?? null,
			createdAt: Date.now(),
		})
		.onConflictDoNothing({ target: [transactions.smsId] })
		.returning({ id: transactions.id });

	return created[0]?.id ?? null;
}

/**
 * Re-runs the parser against a stored message and updates it in place.
 *
 * Used after adding an AI key, or after shipping a new regex: previously
 * `pending` messages can become `parsed` without re-uploading the inbox.
 */
export async function reparseSms(
	env: Env,
	db: Database,
	row: SmsMessageRow,
): Promise<IngestResult> {
	const outcome = await parseSms(env, { sender: row.sender, body: row.body });

	await db
		.update(smsMessages)
		.set({
			provider: outcome.provider,
			parseStatus: outcome.parseStatus,
			parseError: outcome.parseError ?? null,
			parseSource: outcome.parseSource,
			rawExtract: serializeExtract(outcome),
		})
		.where(eq(smsMessages.id, row.id));

	const result: IngestResult = {
		smsId: row.id,
		outcome: outcome.parseStatus === "failed" ? "not_payment" : "inserted",
		provider: outcome.provider,
		parseStatus: outcome.parseStatus,
		parseSource: outcome.parseSource,
		transactionId: null,
		...(outcome.detail === undefined ? {} : { detail: outcome.detail }),
	};

	if (outcome.parseStatus === "parsed" && outcome.extract) {
		result.transactionId = await bookTransaction(db, {
			shopId: row.shopId,
			smsId: row.id,
			direction: outcome.extract.direction,
			amountMinor: outcome.extract.amountMinor,
			currency: outcome.currency,
			counterparty: outcome.extract.counterparty,
			reference: outcome.extract.reference,
			paymentMethod: outcome.provider === "unknown" ? undefined : outcome.provider,
			occurredAt: row.receivedAt,
			note: `Reparsed from ${outcome.provider} SMS`,
		});
	}

	return result;
}

/** Confirms the shop exists before an ingest loop starts. */
export async function shopExists(db: Database, shopId: string): Promise<boolean> {
	const [row] = await db.select({ id: shops.id }).from(shops).where(eq(shops.id, shopId)).limit(1);
	return Boolean(row);
}

/**
 * JSON blob kept for audit and for the reparse UI.
 * On the low-confidence LLM path the model's guess is recorded here for a
 * human to look at, even though no transaction was booked from it.
 */
function serializeExtract(outcome: ParseOutcome): string | null {
	if (!outcome.extract && outcome.parseStatus !== "pending") return null;
	return JSON.stringify({
		extract: outcome.extract,
		currency: outcome.currency,
		confidence: outcome.confidence,
		detail: outcome.detail,
	});
}
