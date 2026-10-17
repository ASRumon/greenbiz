import { compare, hash } from "bcryptjs";
import { SignJWT, jwtVerify } from "jose";

/**
 * Password hashing and session tokens.
 *
 * Hashing: bcryptjs, pure JS (no native addon), so it runs on Workers with the
 * `nodejs_compat` flag. Cost 10 is ~100ms on a Worker isolate - the deliberate
 * tradeoff is that login is slow enough to make offline cracking expensive
 * while staying inside the CPU budget.
 *
 * Sessions: JWT HS256 signed with the JWT_SECRET Worker secret. The secret is
 * passed in per call and never stored in a module-level variable, so a
 * misconfigured request fails loudly instead of reusing another request's key.
 */

/** bcrypt cost factor. Higher = slower to crack = slower to log in. */
const BCRYPT_ROUNDS = 10;

/** Session lifetime: 30 days, per the spec. */
const SESSION_TTL_SECONDS = 60 * 60 * 24 * 30;

/** A valid bcrypt hash of a random string, used to equalize login timing. */
const DUMMY_HASH = "$2b$10$CwTycUXWue0Thq9StjUM0uJ8bqjCgHOGmCJqM4yZ1oM5Nf7Z2r7Uq";

export async function hashPassword(plainText: string): Promise<string> {
	return hash(plainText, BCRYPT_ROUNDS);
}

/**
 * Constant-ish time password check. Returns false rather than throwing on a
 * malformed stored hash, so a corrupted row cannot 500 the login endpoint.
 */
export async function verifyPassword(plainText: string, passwordHash: string): Promise<boolean> {
	try {
		return await compare(plainText, passwordHash);
	} catch {
		return false;
	}
}

/**
 * Burns roughly the same CPU as a real `compare` when the username does not
 * exist. Without this, "unknown username" returns in ~1ms while a wrong
 * password takes ~100ms, which is a usable account-enumeration oracle.
 */
export async function burnPasswordTime(plainText: string): Promise<void> {
	await verifyPassword(plainText, DUMMY_HASH);
}

const encoder = new TextEncoder();
const signingKey = (secret: string) => encoder.encode(secret);

export interface SessionPayload {
	/** User id. */
	sub: string;
	/** Issued at, seconds since epoch. */
	iat: number;
	/** Expiry, seconds since epoch. */
	exp: number;
}

export async function signSessionToken(userId: string, secret: string): Promise<string> {
	const issuedAt = Math.floor(Date.now() / 1000);
	return new SignJWT({})
		.setProtectedHeader({ alg: "HS256", typ: "JWT" })
		.setSubject(userId)
		.setIssuedAt(issuedAt)
		.setExpirationTime(issuedAt + SESSION_TTL_SECONDS)
		.sign(signingKey(secret));
}

/**
 * Verifies signature + expiry. Returns null for *any* failure (bad signature,
 * expired, wrong algorithm, malformed) so callers cannot accidentally
 * distinguish "expired" from "forged" in their response.
 */
export async function verifySessionToken(
	token: string,
	secret: string,
): Promise<SessionPayload | null> {
	try {
		// Pinning `algorithms` blocks algorithm-confusion attacks (e.g. a token
		// that asks to be verified with `none` or with a public key as HMAC key).
		const { payload } = await jwtVerify(token, signingKey(secret), {
			algorithms: ["HS256"],
		});
		if (typeof payload.sub !== "string" || payload.sub.length === 0) return null;
		if (typeof payload.iat !== "number" || typeof payload.exp !== "number") return null;
		return { sub: payload.sub, iat: payload.iat, exp: payload.exp };
	} catch {
		return null;
	}
}
