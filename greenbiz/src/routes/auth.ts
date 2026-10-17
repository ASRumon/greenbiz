import { Hono } from "hono";
import { eq, or } from "drizzle-orm";
import { z } from "zod";
import { shops, users } from "../db/schema";
import type { AppBindings } from "../lib/context";
import { currentUserId } from "../lib/context";
import { requireJwtSecret } from "../lib/env";
import { badRequest, conflict, unauthorized } from "../lib/errors";
import { optionalEmail, optionalText } from "../lib/schemas";
import { parseJsonBody } from "../lib/validate";
import { requireAuth } from "../middleware/auth";
import {
	burnPasswordTime,
	hashPassword,
	signSessionToken,
	verifyPassword,
} from "../services/auth";

export const authRoutes = new Hono<AppBindings>();

/* -------------------------------------------------------------------------- */
/* Schemas                                                                     */
/* -------------------------------------------------------------------------- */

const usernameSchema = z
	.string()
	.trim()
	.min(3, "Username must be at least 3 characters")
	.max(32, "Username must be at most 32 characters")
	.regex(/^[a-zA-Z0-9_.]+$/, "Use letters, numbers, dot, or underscore only")
	.transform((value) => value.toLowerCase());

const passwordSchema = z
	.string()
	.min(8, "Password must be at least 8 characters")
	.max(128, "Password must be at most 128 characters");

const registerSchema = z.object({
	fullName: z.string().trim().min(2, "Full name is required").max(120),
	username: usernameSchema,
	email: optionalEmail,
	password: passwordSchema,
	shopName: optionalText(120),
	businessType: optionalText(60),
});

const loginSchema = z.object({
	username: z.string().trim().min(1, "Username is required").max(160),
	password: z.string().min(1, "Password is required").max(128),
});

/* -------------------------------------------------------------------------- */
/* Serialization                                                               */
/* -------------------------------------------------------------------------- */

/**
 * The ONLY place a user row is converted to JSON.
 * `password_hash` is never selected into this shape, so it cannot be leaked by
 * forgetting a `delete`.
 */
interface PublicUser {
	id: string;
	fullName: string;
	username: string;
	email: string | null;
	createdAt: number;
}

function toPublicUser(row: {
	id: string;
	fullName: string;
	username: string;
	email: string | null;
	createdAt: number;
}): PublicUser {
	return {
		id: row.id,
		fullName: row.fullName,
		username: row.username,
		email: row.email,
		createdAt: row.createdAt,
	};
}

/* -------------------------------------------------------------------------- */
/* POST /api/auth/register                                                     */
/* -------------------------------------------------------------------------- */

authRoutes.post("/register", async (c) => {
	const input = await parseJsonBody(c, registerSchema);
	const db = c.get("db");

	// Check both unique columns up front so the client gets a precise message
	// instead of a raw D1 UNIQUE constraint failure.
	const existing = await db
		.select({ id: users.id, username: users.username, email: users.email })
		.from(users)
		.where(
			input.email
				? or(eq(users.username, input.username), eq(users.email, input.email))
				: eq(users.username, input.username),
		)
		.limit(2);

	if (existing.some((row) => row.username === input.username)) {
		throw conflict("That username is already taken");
	}
	if (input.email && existing.some((row) => row.email === input.email)) {
		throw conflict("That email is already registered");
	}

	const now = Date.now();
	const userId = crypto.randomUUID();

	await db.insert(users).values({
		id: userId,
		fullName: input.fullName,
		username: input.username,
		email: input.email ?? null,
		passwordHash: await hashPassword(input.password),
		createdAt: now,
	});

	// Give every new account a shop immediately. Without this the Inventory tab
	// has nothing to attach products to, and a first-time user would have to
	// discover the shop-creation step before they can do anything useful.
	const shopId = crypto.randomUUID();
	await db.insert(shops).values({
		id: shopId,
		ownerId: userId,
		shopName: input.shopName ?? `${input.fullName.split(" ")[0]}'s Shop`,
		businessType: input.businessType ?? "retail",
		phone: null,
		address: null,
		createdAt: now,
	});

	const [created] = await db.select().from(users).where(eq(users.id, userId)).limit(1);
	if (!created) throw new Error("User insert did not persist");

	// Sign the user straight in so registration is a single round trip.
	const token = await signSessionToken(userId, requireJwtSecret(c.env));

	return c.json({ token, user: toPublicUser(created), shopId }, 201);
});

/* -------------------------------------------------------------------------- */
/* POST /api/auth/login                                                        */
/* -------------------------------------------------------------------------- */

authRoutes.post("/login", async (c) => {
	const input = await parseJsonBody(c, loginSchema);
	const db = c.get("db");

	// Allow signing in with either the username or the email address. Both
	// columns are unique, so at most one row can match.
	const identifier = input.username.toLowerCase();
	const [row] = await db
		.select()
		.from(users)
		.where(or(eq(users.username, identifier), eq(users.email, identifier)))
		.limit(1);

	if (!row) {
		// Spend the same CPU as a real bcrypt compare so response time does not
		// reveal whether the account exists.
		await burnPasswordTime(input.password);
		throw unauthorized("Incorrect username or password");
	}

	if (!(await verifyPassword(input.password, row.passwordHash))) {
		throw unauthorized("Incorrect username or password");
	}

	const token = await signSessionToken(row.id, requireJwtSecret(c.env));
	return c.json({ token, user: toPublicUser(row) });
});

/* -------------------------------------------------------------------------- */
/* GET /api/auth/me                                                            */
/* -------------------------------------------------------------------------- */

authRoutes.get("/me", requireAuth, async (c) => {
	const userId = currentUserId(c);
	const db = c.get("db");

	const [row] = await db.select().from(users).where(eq(users.id, userId)).limit(1);
	if (!row) throw unauthorized("Session no longer valid");

	const ownedShops = await db
		.select()
		.from(shops)
		.where(eq(shops.ownerId, userId))
		.orderBy(shops.createdAt);

	return c.json({
		user: toPublicUser(row),
		shops: ownedShops,
	});
});
