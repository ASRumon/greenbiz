/**
 * Drizzle schema for Cloudflare D1 (SQLite).
 *
 * Ported from the Postgres design doc using these adaptation rules:
 *   UUID          -> TEXT primary key, generated with crypto.randomUUID() in app code
 *   TIMESTAMPTZ   -> INTEGER (Unix milliseconds)
 *   MONEY         -> INTEGER minor units (poisha / paisa). Never float.
 *   JSONB         -> TEXT containing JSON, validated with Zod on read and write
 *   BOOLEAN       -> INTEGER 0/1 (Drizzle `mode: "boolean"`)
 *
 * `pgcrypto` and DB-level `gen_random_uuid()` are dropped: D1 has no extensions
 * and IDs are generated in the Worker so they are available before insert.
 */
import { index, integer, real, sqliteTable, text, uniqueIndex } from "drizzle-orm/sqlite-core";

/* -------------------------------------------------------------------------- */
/* Identity                                                                    */
/* -------------------------------------------------------------------------- */

export const users = sqliteTable("users", {
	id: text("id").primaryKey(),
	fullName: text("full_name").notNull(),
	username: text("username").notNull().unique(),
	email: text("email").unique(),
	passwordHash: text("password_hash").notNull(),
	createdAt: integer("created_at").notNull(),
});

export const shops = sqliteTable(
	"shops",
	{
		id: text("id").primaryKey(),
		ownerId: text("owner_id")
			.notNull()
			.references(() => users.id, { onDelete: "cascade" }),
		shopName: text("shop_name").notNull(),
		businessType: text("business_type"),
		phone: text("phone"),
		address: text("address"),
		createdAt: integer("created_at").notNull(),
	},
	(t) => [index("shops_owner_idx").on(t.ownerId)],
);

/* -------------------------------------------------------------------------- */
/* Inventory                                                                   */
/* -------------------------------------------------------------------------- */

export const products = sqliteTable(
	"products",
	{
		id: text("id").primaryKey(),
		shopId: text("shop_id")
			.notNull()
			.references(() => shops.id, { onDelete: "cascade" }),
		productName: text("product_name").notNull(),
		unit: text("unit").notNull(),
		/** Selling price in minor units (poisha / paisa). */
		unitPriceMinor: integer("unit_price_minor").notNull(),
		/** REAL because stock supports fractional units (e.g. 2.5 kg). */
		stockQuantity: real("stock_quantity").notNull().default(0),
		createdAt: integer("created_at").notNull(),
	},
	(t) => [index("products_shop_idx").on(t.shopId)],
);

/* -------------------------------------------------------------------------- */
/* Financial product catalogue (public directory)                              */
/* -------------------------------------------------------------------------- */

export const financialInstitutions = sqliteTable("financial_institutions", {
	id: text("id").primaryKey(),
	name: text("name").notNull(),
	/** commercial_bank | nbfi | mfi | mfs | insurance | cooperative | fintech */
	institutionType: text("institution_type").notNull(),
	website: text("website"),
	description: text("description"),
	contactPhone: text("contact_phone"),
	isActive: integer("is_active", { mode: "boolean" }).notNull().default(true),
	createdAt: integer("created_at").notNull(),
});

export const financialServicePlans = sqliteTable(
	"financial_service_plans",
	{
		id: text("id").primaryKey(),
		institutionId: text("institution_id")
			.notNull()
			.references(() => financialInstitutions.id, { onDelete: "cascade" }),
		planName: text("plan_name").notNull(),
		/** loan | insurance | savings | current_account | working_capital */
		serviceType: text("service_type").notNull(),
		description: text("description"),
		minAmountMinor: integer("min_amount_minor"),
		maxAmountMinor: integer("max_amount_minor"),
		/** Percentage per annum, e.g. 9.5. Stored as REAL because rates are not money. */
		interestRateMin: real("interest_rate_min"),
		interestRateMax: real("interest_rate_max"),
		durationMonths: integer("duration_months"),
		/** JSON text: { minMonthlyRevenueMinor, requiresCollateral, ... } */
		eligibilityCriteria: text("eligibility_criteria"),
		/** JSON text: { processingFeePct, insurancePremiumPct, ... } */
		feesDetails: text("fees_details"),
		sourceUrl: text("source_url"),
		lastVerifiedAt: integer("last_verified_at"),
		isActive: integer("is_active", { mode: "boolean" }).notNull().default(true),
		createdAt: integer("created_at").notNull(),
	},
	(t) => [
		index("plans_institution_idx").on(t.institutionId),
		index("plans_service_type_idx").on(t.serviceType),
	],
);

/* -------------------------------------------------------------------------- */
/* Mobile money ingest                                                         */
/* -------------------------------------------------------------------------- */

export const smsMessages = sqliteTable(
	"sms_messages",
	{
		id: text("id").primaryKey(),
		shopId: text("shop_id")
			.notNull()
			.references(() => shops.id, { onDelete: "cascade" }),
		/** Provider display name as it appears in the inbox, e.g. "bKash", "16247". */
		sender: text("sender").notNull(),
		/** Raw SMS body. Stored verbatim; never shared with a lender. */
		body: text("body").notNull(),
		receivedAt: integer("received_at").notNull(),
		/** bkash | nagad | rocket | upay | upi | unknown */
		provider: text("provider").notNull(),
		/** pending | parsed | failed */
		parseStatus: text("parse_status").notNull(),
		parseError: text("parse_error"),
		/** regex | llm | null */
		parseSource: text("parse_source"),
		/** JSON text of the fields extracted by the parser. */
		rawExtract: text("raw_extract"),
		createdAt: integer("created_at").notNull(),
	},
	(t) => [
		// Idempotency key for bulk sync: re-uploading the same inbox must not
		// create duplicate SMS rows.
		uniqueIndex("sms_messages_dedupe_idx").on(t.shopId, t.sender, t.body, t.receivedAt),
		index("sms_messages_shop_received_idx").on(t.shopId, t.receivedAt),
		index("sms_messages_shop_status_idx").on(t.shopId, t.parseStatus),
	],
);

export const transactions = sqliteTable(
	"transactions",
	{
		id: text("id").primaryKey(),
		shopId: text("shop_id")
			.notNull()
			.references(() => shops.id, { onDelete: "cascade" }),
		/** Null for manually entered transactions. */
		smsId: text("sms_id").references(() => smsMessages.id, { onDelete: "set null" }),
		/** in | out */
		direction: text("direction").notNull(),
		amountMinor: integer("amount_minor").notNull(),
		/** BDT | INR */
		currency: text("currency").notNull(),
		counterparty: text("counterparty"),
		/** Mobile money TrxID. */
		reference: text("reference"),
		occurredAt: integer("occurred_at").notNull(),
		note: text("note"),
		/** cash | bkash | nagad | rocket | upay | upi | other. Null on legacy rows. */
		paymentMethod: text("payment_method"),
		/**
		 * Client-generated sale id, for idempotent retries (including merged and
		 * split sales). A split sale has two rows with the same id: the mobile
		 * money row and the cash balance row.
		 */
		saleId: text("sale_id"),
		/**
		 * The list-price bill before a round-off/discount. A shop that rounds
		 * ৳257 down to ৳250 stores 25700 here. Zero for manual payments and on
		 * the cash half of a split sale (the primary row carries the bill).
		 */
		subtotalMinor: integer("subtotal_minor").notNull().default(0),
		/**
		 * List-price bill minus the amount actually collected. A shop that
		 * rounds ৳257 down to ৳250 stores 700 here and records 25000 as the
		 * inflow. Zero for manual payments and ordinary sales.
		 */
		discountMinor: integer("discount_minor").notNull().default(0),
		/**
		 * False when the owner marked this as personal, not business. Personal rows
		 * stay visible in the ledger but are excluded from credit scoring and
		 * business cash-flow totals.
		 */
		isBusiness: integer("is_business", { mode: "boolean" }).notNull().default(true),
		createdAt: integer("created_at").notNull(),
	},
	(t) => [
		index("transactions_shop_occurred_idx").on(t.shopId, t.occurredAt),
		index("transactions_shop_direction_idx").on(t.shopId, t.direction),
		// One SMS can produce at most one transaction.
		uniqueIndex("transactions_sms_unique_idx").on(t.smsId),
		// A client sale normally produces one row. A split payment (part mobile
		// money, part cash) produces two rows that share the sale id, so this is
		// deliberately NOT unique. Idempotency is enforced by the sale endpoint,
		// which looks up every row for the sale before writing.
		index("transactions_sale_id_idx").on(t.saleId),
	],
);

/* -------------------------------------------------------------------------- */
/* Derived credit signal                                                       */
/* -------------------------------------------------------------------------- */

export const creditProfiles = sqliteTable("credit_profiles", {
	shopId: text("shop_id")
		.primaryKey()
		.references(() => shops.id, { onDelete: "cascade" }),
	/** 0-100 */
	score: integer("score").notNull(),
	/** JSON text: { consistency: {score,weight}, volume: {...}, ... } */
	factors: text("factors").notNull(),
	monthlyRevenueAvgMinor: integer("monthly_revenue_avg_minor").notNull(),
	/** 0..1 coefficient of variation across monthly inflow. */
	monthlyVolatility: real("monthly_volatility").notNull(),
	transactionCount90d: integer("transaction_count_90d").notNull(),
	computedAt: integer("computed_at").notNull(),
});

/* -------------------------------------------------------------------------- */
/* Loan matching (table created, routes intentionally not built - see §11)      */
/* -------------------------------------------------------------------------- */

export const loanApplications = sqliteTable(
	"loan_applications",
	{
		id: text("id").primaryKey(),
		shopId: text("shop_id")
			.notNull()
			.references(() => shops.id, { onDelete: "cascade" }),
		planId: text("plan_id")
			.notNull()
			.references(() => financialServicePlans.id),
		/** draft | submitted | verified | approved | rejected */
		status: text("status").notNull().default("draft"),
		notes: text("notes"),
		createdAt: integer("created_at").notNull(),
	},
	(t) => [index("loan_applications_shop_idx").on(t.shopId)],
);

/* -------------------------------------------------------------------------- */
/* Inferred row types                                                          */
/* -------------------------------------------------------------------------- */

export type UserRow = typeof users.$inferSelect;
export type NewUserRow = typeof users.$inferInsert;
export type ShopRow = typeof shops.$inferSelect;
export type NewShopRow = typeof shops.$inferInsert;
export type ProductRow = typeof products.$inferSelect;
export type NewProductRow = typeof products.$inferInsert;
export type InstitutionRow = typeof financialInstitutions.$inferSelect;
export type PlanRow = typeof financialServicePlans.$inferSelect;
export type SmsMessageRow = typeof smsMessages.$inferSelect;
export type NewSmsMessageRow = typeof smsMessages.$inferInsert;
export type TransactionRow = typeof transactions.$inferSelect;
export type NewTransactionRow = typeof transactions.$inferInsert;
export type CreditProfileRow = typeof creditProfiles.$inferSelect;
export type LoanApplicationRow = typeof loanApplications.$inferSelect;
