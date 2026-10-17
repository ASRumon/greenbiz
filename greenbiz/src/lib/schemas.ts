import { z } from "zod";

/** Shared Zod primitives reused across route modules. */

/** UUID v4 string. Every primary key is a `crypto.randomUUID()` value. */
export const uuid = z.uuid("Must be a valid UUID");

/** Money in minor units: a non-negative integer. Never a float. */
export const minorUnits = z.number().int("Amount must be a whole number of minor units").nonnegative("Amount cannot be negative");

/** Unix milliseconds timestamp. */
export const timestampMs = z.number().int().nonnegative().max(4102444800000, "Timestamp is too far in the future");

/** Trimmed, non-empty display name. */
export const displayName = (label: string, max = 120) =>
	z.string().trim().min(1, `${label} is required`).max(max, `${label} must be at most ${max} characters`);

/**
 * Accepts `undefined`, `null`, or an empty/whitespace string as "not provided",
 * so a Flutter form that submits `""` for an untouched field does not 400.
 */
export const optionalText = (max: number) =>
	z.preprocess(
		(value) => {
			if (value === null || value === undefined) return undefined;
			if (typeof value === "string" && value.trim() === "") return undefined;
			return value;
		},
		z.string().trim().max(max, `Must be at most ${max} characters`).optional(),
	);

/** Same "empty means absent" rule, but validated as an email address. */
export const optionalEmail = z.preprocess(
	(value) => {
		if (value === null || value === undefined) return undefined;
		if (typeof value === "string" && value.trim() === "") return undefined;
		return typeof value === "string" ? value.trim().toLowerCase() : value;
	},
	z.email("Must be a valid email address").max(160).optional(),
);

/** Pagination for list endpoints. */
export const paginationQuery = z.object({
	limit: z.coerce.number().int().min(1).max(500).default(100),
	offset: z.coerce.number().int().min(0).default(0),
});

/**
 * Turns "field was not sent" into `undefined`.
 *
 * `z.coerce.number()` maps `null` to `0` and `""` to `0`, which would silently
 * wipe a value on a PATCH. Normalising null/empty first keeps "absent" and
 * "explicitly zero" distinguishable.
 */
const absentAsUndefined = (value: unknown) =>
	value === null || value === undefined || value === "" ? undefined : value;

/** Optional money field for PATCH bodies. Integer minor units. */
export const optionalMinorUnits = z.preprocess(
	absentAsUndefined,
	z.coerce
		.number()
		.int("Amount must be a whole number of minor units")
		.nonnegative("Amount cannot be negative")
		.optional(),
);

/** Optional quantity field for PATCH bodies. */
export const optionalQuantity = z.preprocess(
	absentAsUndefined,
	z.coerce
		.number()
		.nonnegative("Quantity cannot be negative")
		.max(100_000_000, "Quantity is unreasonably large")
		.optional(),
);

/** Required quantity field for create bodies. */
export const quantity = z.coerce
	.number()
	.nonnegative("Quantity cannot be negative")
	.max(100_000_000, "Quantity is unreasonably large");

/** Currency codes supported by the app. */
export const currencyCode = z.enum(["BDT", "INR"]);

/** How a payment moved. Cash is the default for a sale. */
export const paymentMethod = z.enum([
	"cash",
	"bkash",
	"nagad",
	"rocket",
	"upay",
	"upi",
	"other",
]);

export const paymentDirection = z.enum(["in", "out"]);
