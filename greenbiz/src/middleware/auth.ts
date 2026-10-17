import { createMiddleware } from "hono/factory";
import type { AppBindings } from "../lib/context";
import { unauthorized } from "../lib/errors";
import { requireAdminToken, requireJwtSecret } from "../lib/env";
import { verifySessionToken } from "../services/auth";

/**
 * Session guard for every non-public route.
 *
 * Reads `Authorization: Bearer <jwt>`, verifies it, and puts the user id on the
 * context. Throws 401 (never 403) for a missing, malformed, expired, or forged
 * token, so probing the endpoint reveals nothing about which users exist.
 *
 * The token itself is never logged and never echoed back in a response.
 */
export const requireAuth = createMiddleware<AppBindings>(async (c, next) => {
	const header = c.req.header("Authorization");
	if (!header) throw unauthorized("Missing Authorization header");

	const [scheme, ...rest] = header.split(" ");
	if (scheme?.toLowerCase() !== "bearer" || rest.length === 0) {
		throw unauthorized("Expected: Authorization: Bearer <token>");
	}

	const token = rest.join(" ").trim();
	if (!token) throw unauthorized("Empty bearer token");

	const session = await verifySessionToken(token, requireJwtSecret(c.env));
	if (!session) throw unauthorized("Invalid or expired session");

	c.set("userId", session.sub);
	await next();
});

/**
 * Guard for operator-only endpoints. Uses a constant-time compare against
 * `ADMIN_TOKEN` so the comparison cannot be timed character by character.
 */
export const requireAdmin = createMiddleware<AppBindings>(async (c, next) => {
	const expected = requireAdminToken(c.env);

	const header = c.req.header("Authorization") ?? "";
	const provided = header.toLowerCase().startsWith("bearer ")
		? header.slice(7).trim()
		: header.trim();

	if (!(await timingSafeEqual(provided, expected))) {
		throw unauthorized("Invalid admin token");
	}
	await next();
});

/**
 * Constant-time string comparison.
 *
 * Workers has no `crypto.timingSafeEqual`, so both inputs are SHA-256'd first:
 * the digests are always 32 bytes, so the loop below runs a fixed number of
 * iterations regardless of input length and never short-circuits on the first
 * differing byte.
 */
async function timingSafeEqual(a: string, b: string): Promise<boolean> {
	const encoder = new TextEncoder();
	const [aDigest, bDigest] = await Promise.all([
		crypto.subtle.digest("SHA-256", encoder.encode(a)),
		crypto.subtle.digest("SHA-256", encoder.encode(b)),
	]);

	const aBytes = new Uint8Array(aDigest);
	const bBytes = new Uint8Array(bDigest);

	let difference = 0;
	for (let i = 0; i < aBytes.length; i += 1) {
		difference |= (aBytes[i] ?? 0) ^ (bBytes[i] ?? 0);
	}
	return difference === 0;
}
