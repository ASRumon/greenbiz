import { z } from "zod";

/**
 * Secret + config validation.
 *
 * Cloudflare Worker *vars* are declared in `wrangler.jsonc` and land in the
 * generated `Env` type via `npm run cf-typegen`. *Secrets* are invisible to
 * that generation, so they are declared here as optional and then validated
 * with Zod at request time — a missing `JWT_SECRET` should surface as a clear
 * 500 `CONFIG_ERROR`, not as `undefined` leaking into a signature call.
 *
 * Nothing in this file logs, echoes, or returns a secret value.
 */
declare global {
	interface Env {
		/** HS256 signing key for session JWTs. Min 32 chars. */
		JWT_SECRET?: string;
		/** Bearer token protecting `POST /api/admin/seed`. Min 16 chars. */
		ADMIN_TOKEN?: string;
		/** Google Gemini API key (primary AI provider). */
		GEMINI_API_KEY?: string;
		/** Additional Gemini keys, used for rotation when the primary is rate limited. */
		GEMINI_API_KEY_2?: string;
		GEMINI_API_KEY_3?: string;
		/** Groq API key (first fallback). */
		GROQ_API_KEY?: string;
		/** OpenRouter API key (second fallback). */
		OPENROUTER_API_KEY?: string;
		/** Optional model override for the AI provider chain. */
		AI_MODEL?: string;
	}
}

/** A secret string that must be present and long enough to be worth anything. */
const secret = (name: string, min: number) =>
	z
		.string({ error: `${name} is not configured. Run: wrangler secret put ${name}` })
		.min(min, `${name} must be at least ${min} characters`);

const optionalKey = z.string().min(1).optional();

export const envSchema = z.object({
	DB: z.custom<D1Database>(
		(value) =>
			typeof value === "object" &&
			value !== null &&
			typeof (value as D1Database).prepare === "function",
		{ error: "D1 binding `DB` is missing. Check d1_databases in wrangler.jsonc." },
	),
	ENVIRONMENT: z.enum(["development", "production", "test"]).default("development"),
	JWT_SECRET: secret("JWT_SECRET", 32),
	ADMIN_TOKEN: secret("ADMIN_TOKEN", 16),
	GEMINI_API_KEY: optionalKey,
	GEMINI_API_KEY_2: optionalKey,
	GEMINI_API_KEY_3: optionalKey,
	GROQ_API_KEY: optionalKey,
	OPENROUTER_API_KEY: optionalKey,
	AI_MODEL: z.string().min(1).optional(),
});

export type AppEnv = z.infer<typeof envSchema>;

/**
 * Validates a single value with Zod and throws `ConfigError` on failure.
 * Keeps every "the deploy is misconfigured" failure in one place.
 */
function parseOrThrow<T>(schema: z.ZodType<T>, value: unknown, label: string): T {
	const result = schema.safeParse(value);
	if (!result.success) {
		const details = result.error.issues.map((issue) => issue.message).join("; ");
		throw new ConfigError(`${label}: ${details}`);
	}
	return result.data;
}

/** Raised when the Worker is missing required configuration. Maps to HTTP 500. */
export class ConfigError extends Error {
	readonly code = "CONFIG_ERROR";
	constructor(message: string) {
		super(message);
		this.name = "ConfigError";
	}
}

/** Full-environment validation. Use when a handler needs several bindings at once. */
export function parseEnv(env: Env): AppEnv {
	return parseOrThrow(envSchema, env, "Invalid Worker environment");
}

/** The D1 binding. Cheap to call; no secret involved. */
export function requireDb(env: Env): D1Database {
	return parseOrThrow(envSchema.shape.DB, env.DB, "Invalid Worker environment");
}

/** The JWT signing key, validated for length before use. */
export function requireJwtSecret(env: Env): string {
	return parseOrThrow(secret("JWT_SECRET", 32), env.JWT_SECRET, "Invalid Worker environment");
}

/** The admin bearer token, validated for length before use. */
export function requireAdminToken(env: Env): string {
	return parseOrThrow(secret("ADMIN_TOKEN", 16), env.ADMIN_TOKEN, "Invalid Worker environment");
}

/**
 * All configured AI keys, in fallback order: Gemini (primary, plus any
 * rotation keys) -> Groq -> OpenRouter. Providers with no key are skipped.
 *
 * Returns provider descriptors rather than a map so ordering is explicit and
 * cannot be accidentally changed by object key iteration order.
 */
export function getAiKeys(env: Env): {
	gemini: string[];
	groq?: string;
	openRouter?: string;
} {
	const gemini = [env.GEMINI_API_KEY, env.GEMINI_API_KEY_2, env.GEMINI_API_KEY_3].filter(
		(key): key is string => typeof key === "string" && key.length > 0,
	);
	return {
		gemini,
		groq: env.GROQ_API_KEY && env.GROQ_API_KEY.length > 0 ? env.GROQ_API_KEY : undefined,
		openRouter:
			env.OPENROUTER_API_KEY && env.OPENROUTER_API_KEY.length > 0
				? env.OPENROUTER_API_KEY
				: undefined,
	};
}

/** True when at least one AI provider is configured. Never reveals which. */
export function hasAnyAiProvider(env: Env): boolean {
	const keys = getAiKeys(env);
	return keys.gemini.length > 0 || Boolean(keys.groq) || Boolean(keys.openRouter);
}
