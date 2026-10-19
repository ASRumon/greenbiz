import { Hono } from "hono";
import { and, eq, inArray } from "drizzle-orm";
import type { BatchItem } from "drizzle-orm/batch";
import { z } from "zod";
import { products, transactions } from "../db/schema";
import type { AppBindings } from "../lib/context";
import { currentUserId } from "../lib/context";
import { AppError, badRequest, conflict, notFound } from "../lib/errors";
import { resolveSalePayment } from "../lib/paymentTolerance";
import { minorUnits, optionalText, paymentMethod, timestampMs, uuid } from "../lib/schemas";
import { parseJsonBody, parseParams } from "../lib/validate";
import { requireAuth } from "../middleware/auth";
import { recomputeCreditProfile } from "../services/creditScore";
import { requireOwnedShop } from "../services/shopAccess";
import { ingestSms, resolveShopCurrency } from "../services/smsIngest";

/**
 * Selling from inventory.
 *
 * Mounted at `/api` because the path is shop-scoped:
 *   POST /api/shops/:shopId/sales
 *
 * A sale writes two things that must never disagree: the money coming in
 * (a transaction row) and the stock going down (one product update per line).
 * D1 `batch()` runs the whole list as one transaction, so a failure part-way
 * through leaves neither change applied.
 */
export const saleRoutes = new Hono<AppBindings>();

/* -------------------------------------------------------------------------- */
/* Schemas                                                                     */
/* -------------------------------------------------------------------------- */

const shopIdParam = z.object({ shopId: uuid });

const saleItemSchema = z.object({
	productId: uuid,
	quantity: z
		.number()
		.positive("Quantity must be greater than zero")
		.max(1_000_000, "Quantity is unreasonably large"),
});

const createSaleSchema = z.object({
	/** Client-generated transaction id, for safe retries after a dropped reply. */
	id: uuid.optional(),
	items: z.array(saleItemSchema).min(1, "Add at least one product").max(50),
	counterparty: optionalText(120),
	occurredAt: timestampMs.optional(),
	note: optionalText(240),
	/** cash | bkash | nagad | rocket | upay | upi | other. Defaults to cash. */
	paymentMethod: paymentMethod.optional(),
	/** Mobile-money TrxID, when the owner matched an SMS confirmation. */
	reference: optionalText(64),
	/** SMS message id of the confirmation row. Merges instead of double-booking. */
	smsId: uuid.optional(),
	/**
	 * Cash the customer handed over on top of a mobile-money message.
	 *
	 * Bangladesh shops routinely take part of a bill by bKash/Nagad and the rest
	 * from the till. When this is set, the message row keeps its real amount and
	 * a second cash row is booked, so the ledger adds up to the sale instead of
	 * losing the cash (or counting the message twice).
	 */
	cashMinor: minorUnits.optional(),
	/**
	 * What the shopkeeper actually decided to collect.
	 *
	 * Shops round a bill down ("৳257, give me ৳250") or knock a few taka off
	 * for a regular. The transaction records this amount, the difference from
	 * the list-price bill is stored as a discount, and mobile-money matching
	 * uses it too — so a ৳250 message is an exact match for the ৳250 collected,
	 * not a ৳7 mismatch.
	 */
	payableMinor: minorUnits.optional(),
	/**
	 * A confirmation captured live on the phone. When the sale is retried after
	 * an offline period the SMS may not have been uploaded yet, so the server
	 * ingests it here and can still merge the two into one ledger row.
	 */
	liveSms: z
		.object({
			sender: z.string().trim().min(1).max(64),
			body: z.string().min(1).max(2000),
			receivedAt: timestampMs,
		})
		.optional(),
});

/** "3" for 3.0, "2.5" for 2.50 — how a shopkeeper writes a quantity. */
function quantityLabel(quantity: number): string {
	return Number.isInteger(quantity) ? String(quantity) : String(Number(quantity.toFixed(2)));
}

/** `৳1,257` / `৳7.50` for the note, which the owner reads in Payments. */
function moneyLabel(minor: number): string {
	const whole = Math.floor(minor / 100);
	const fraction = minor % 100;
	const grouped = whole.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
	return fraction === 0
		? `৳${grouped}`
		: `৳${grouped}.${String(fraction).padStart(2, "0")}`;
}

/* -------------------------------------------------------------------------- */
/* POST /api/shops/:shopId/sales                                               */
/* -------------------------------------------------------------------------- */

saleRoutes.post("/shops/:shopId/sales", requireAuth, async (c) => {
	const { shopId } = parseParams(c, shopIdParam);
	const input = await parseJsonBody(c, createSaleSchema);
	const db = c.get("db");

	await requireOwnedShop(db, shopId, currentUserId(c));

	// A live capture may not have reached the server yet. Ingest it before the
	// stock check so the merge path below can treat it like any other message.
	// The ingest is idempotent, so a retry after a dropped response is safe.
	let smsId = input.smsId;
	if (!smsId && input.liveSms) {
		const ingested = await ingestSms(c.env, db, shopId, input.liveSms);
		if (ingested.parseStatus === "parsed") smsId = ingested.smsId;
	}

	// A cash balance only makes sense next to a mobile-money message. Rejecting
	// it is safer than booking a cash sale and silently dropping the split.
	if (!smsId && (input.cashMinor ?? 0) > 0) {
		throw badRequest("A cash balance needs a linked payment message");
	}

	// Merge duplicate lines first. Two entries for the same product must be
	// checked against stock together, not independently.
	const wanted = new Map<string, number>();
	for (const item of input.items) {
		wanted.set(item.productId, (wanted.get(item.productId) ?? 0) + item.quantity);
	}

	const rows = await db
		.select()
		.from(products)
		.where(and(eq(products.shopId, shopId), inArray(products.id, [...wanted.keys()])));

	// 404 rather than 403, and the same message for every missing id, so the
	// endpoint cannot be used to probe another shop's product catalogue.
	if (rows.length !== wanted.size) {
		throw notFound("One or more products are not in this shop");
	}

	const byId = new Map(rows.map((row) => [row.id, row]));

	// A retry must not decrement stock twice. The first successful attempt
	// created the ledger row(s) with this sale id; return them instead of
	// writing again. A split payment has two rows (mobile money + cash), so the
	// lookup must consider every row, not just the first.
	if (input.id) {
		const existingRows = await db
			.select()
			.from(transactions)
			.where(and(eq(transactions.saleId, input.id), eq(transactions.shopId, shopId)));

		if (existingRows.length > 0) {
			const smsRow = existingRows.find((row) => row.smsId !== null);
			const cashRow = smsRow ? existingRows.find((row) => row.smsId === null) : undefined;

			const retrySubtotalMinor = [...wanted.entries()].reduce(
				(sum, [productId, quantity]) =>
					sum + Math.round((byId.get(productId)?.unitPriceMinor ?? 0) * quantity),
				0,
			);
			const retryPayableMinor = Math.min(
				input.payableMinor ?? retrySubtotalMinor,
				retrySubtotalMinor,
			);

			return c.json({
				transaction: smsRow ?? existingRows[0],
				cashTransaction: cashRow ?? null,
				cashMinor: cashRow?.amountMinor ?? 0,
				subtotalMinor: retrySubtotalMinor,
				discountMinor: retrySubtotalMinor - retryPayableMinor,
				totalMinor: retryPayableMinor,
				currency: existingRows[0].currency,
				items: [...wanted.entries()].map(([productId, quantity]) => {
					const product = byId.get(productId);
					return {
						productId,
						productName: product?.productName ?? "Product",
						unit: product?.unit ?? "unit",
						quantity,
						unitPriceMinor: product?.unitPriceMinor ?? 0,
						lineTotalMinor: Math.round((product?.unitPriceMinor ?? 0) * quantity),
						remainingStock: product?.stockQuantity ?? 0,
					};
				}),
				score: null,
				smsLinked: Boolean(smsRow),
			});
		}
	}
	const lines: Array<{
		product: (typeof rows)[number];
		quantity: number;
		lineTotalMinor: number;
		remainingStock: number;
	}> = [];
	const insufficient: Array<Record<string, unknown>> = [];
	let subtotalMinor = 0;

	for (const [productId, quantity] of wanted) {
		const product = byId.get(productId);
		if (!product) throw notFound("One or more products are not in this shop");

		// Floating-point stock: compare with a tiny tolerance so 0.1 + 0.2 does
		// not make an exactly-available sale look impossible.
		if (quantity > product.stockQuantity + 1e-9) {
			insufficient.push({
				productId,
				productName: product.productName,
				requested: quantity,
				available: product.stockQuantity,
			});
			continue;
		}

		const lineTotalMinor = Math.round(product.unitPriceMinor * quantity);
		subtotalMinor += lineTotalMinor;
		lines.push({
			product,
			quantity,
			lineTotalMinor,
			// Keep REAL stock tidy: three decimals is finer than any unit sold.
			remainingStock: Math.round((product.stockQuantity - quantity) * 1000) / 1000,
		});
	}

	if (insufficient.length > 0) {
		throw badRequest("Not enough stock for one or more products", insufficient);
	}

	const now = Date.now();
	const currency = await resolveShopCurrency(db, shopId);

	// The bill is what the catalogue says the goods cost. `payableMinor` is
	// what the shopkeeper decided to collect after a round-off or a small
	// discount ("the bill is ৳257, give me ৳250"). Never collect more than the
	// bill: an over-charge with no matching line would make the ledger lie.
	if (input.payableMinor !== undefined && input.payableMinor > subtotalMinor) {
		throw badRequest(
			`The amount to collect cannot be more than the bill (${subtotalMinor} minor units)`,
			{ subtotalMinor, payableMinor: input.payableMinor },
		);
	}
	const payableMinor = input.payableMinor ?? subtotalMinor;
	const discountMinor = subtotalMinor - payableMinor;

	const summary = lines
		.map((line) => `${quantityLabel(line.quantity)} ${line.product.unit} ${line.product.productName}`)
		.join(", ");

	// Keep the discount visible in the ledger row, not only in the receipt the
	// customer saw. This is the note the owner reads in Payments.
	const saleNote = (input.note ?? `Sale: ${summary}${discountMinor > 0 ? ` · ${moneyLabel(discountMinor)} discount` : ""}`).slice(
		0,
		240,
	);

	const saleItems = lines.map((line) => ({
		productId: line.product.id,
		productName: line.product.productName,
		unit: line.product.unit,
		quantity: line.quantity,
		unitPriceMinor: line.product.unitPriceMinor,
		lineTotalMinor: line.lineTotalMinor,
		remainingStock: line.remainingStock,
	}));

	const stockUpdates = () =>
		lines.map((line) =>
			db
				.update(products)
				.set({ stockQuantity: line.remainingStock })
				.where(eq(products.id, line.product.id)),
		);

	// When the owner picked an SMS confirmation for this amount, that row already
	// is the money. Merge into it (stock down, payment metadata) instead of
	// booking a second inflow for the same payment.
	//
	// Mobile money rarely lands on the exact total: the customer adds the
	// cash-out charge (about 10-20 taka per thousand), or the shop absorbs it. A
	// message inside that band still pays for this sale.
	//
	// A short message plus a cash balance is the classic "part bKash, part
	// hand" payment. The message row keeps its real amount and a second cash row
	// is booked for the rest, so the two add up to `payableMinor`.
	if (smsId) {
		const [smsPayment] = await db
			.select()
			.from(transactions)
			.where(and(eq(transactions.shopId, shopId), eq(transactions.smsId, smsId)))
			.limit(1);

		if (!smsPayment && (input.cashMinor ?? 0) > 0) {
			throw badRequest("A cash balance needs a linked payment message");
		}

		if (smsPayment) {
			// A payment message can back exactly one sale. Re-linking it would
			// decrement stock for money that is already accounted for.
			if (smsPayment.saleId && smsPayment.saleId !== input.id) {
				throw conflict("That payment message is already linked to another sale");
			}

			const resolution = resolveSalePayment({
				receivedMinor: smsPayment.amountMinor,
				totalMinor: payableMinor,
				cashMinor: input.cashMinor,
			});

			if (resolution.mode === "invalid") {
				throw badRequest(resolution.message);
			}

			if (resolution.mode === "merge" || resolution.mode === "split") {
				const mergedTransaction = {
					...smsPayment,
					// The client sale id is the retry key; the row keeps its own id.
					saleId: input.id ?? null,
					paymentMethod: input.paymentMethod ?? smsPayment.paymentMethod ?? "cash",
					reference: input.reference ?? smsPayment.reference,
					counterparty: input.counterparty ?? smsPayment.counterparty,
					note: saleNote,
					subtotalMinor,
					discountMinor,
				};

				const link = db
					.update(transactions)
					.set({
						saleId: mergedTransaction.saleId,
						paymentMethod: mergedTransaction.paymentMethod,
						reference: mergedTransaction.reference,
						counterparty: mergedTransaction.counterparty,
						note: mergedTransaction.note,
						subtotalMinor: mergedTransaction.subtotalMinor,
						discountMinor: mergedTransaction.discountMinor,
					})
					.where(eq(transactions.id, smsPayment.id));

				const statements: BatchItem<"sqlite">[] = [...stockUpdates(), link];

				let cashTransaction: typeof transactions.$inferSelect | null = null;
				if (resolution.mode === "split") {
					cashTransaction = {
						id: crypto.randomUUID(),
						shopId,
						smsId: null,
						direction: "in" as const,
						amountMinor: resolution.cashMinor,
						currency,
						counterparty:
							input.counterparty ?? smsPayment.counterparty ?? "Walk-in customer",
						reference: null,
						occurredAt: input.occurredAt ?? now,
						note: `Cash balance: ${summary}`.slice(0, 240),
						isBusiness: true,
						paymentMethod: "cash",
						saleId: input.id ?? null,
						subtotalMinor: 0,
						discountMinor: 0,
						createdAt: now,
					};
					statements.push(db.insert(transactions).values(cashTransaction));
				}

				const [first, ...rest] = statements;
				if (!first) throw new AppError("INTERNAL", "Sale could not be saved");

				await db.batch([first, ...rest] as [BatchItem<"sqlite">, ...BatchItem<"sqlite">[]]);

				let mergedScore: number | null = null;
				try {
					mergedScore = (await recomputeCreditProfile(db, shopId)).score;
				} catch (error) {
					console.error(
						"Credit recompute after linked sale failed:",
						error instanceof Error ? error.message : error,
					);
				}

				return c.json(
					{
						transaction: mergedTransaction,
						cashTransaction,
						cashMinor: resolution.mode === "split" ? resolution.cashMinor : 0,
						subtotalMinor,
						discountMinor,
						totalMinor: payableMinor,
						currency: smsPayment.currency,
						items: saleItems,
						score: mergedScore,
						smsLinked: true,
					},
					200,
				);
			}
		}
	}

	const transaction = {
		id: input.id ?? crypto.randomUUID(),
		shopId,
		smsId: null,
		// Selling goods brings money in.
		direction: "in" as const,
		amountMinor: payableMinor,
		currency,
		counterparty: input.counterparty ?? "Walk-in customer",
		reference: input.reference ?? null,
		occurredAt: input.occurredAt ?? now,
		note: saleNote,
		isBusiness: true,
		paymentMethod: input.paymentMethod ?? "cash",
		saleId: input.id ?? null,
		subtotalMinor,
		discountMinor,
		createdAt: now,
	};

	const insert = db.insert(transactions).values(transaction);

	// Drizzle types `batch` as a non-empty tuple. A sale always has at least one
	// line (enforced by the schema), so the cast is narrow and checked here.
	const statements: BatchItem<"sqlite">[] = [...stockUpdates(), insert];
	const [first, ...rest] = statements;
	if (!first) throw new AppError("INTERNAL", "Sale could not be saved");

	await db.batch([first, ...rest] as [BatchItem<"sqlite">, ...BatchItem<"sqlite">[]]);

	// The ledger write already succeeded; a score failure must not turn a
	// completed sale into an error the user would retry and double-book.
	let score: number | null = null;
	try {
		score = (await recomputeCreditProfile(db, shopId)).score;
	} catch (error) {
		console.error(
			"Credit recompute after sale failed:",
			error instanceof Error ? error.message : error,
		);
	}

	return c.json(
		{
			transaction,
			subtotalMinor,
			discountMinor,
			totalMinor: payableMinor,
			currency,
			items: saleItems,
			score,
		},
		201,
	);
});
