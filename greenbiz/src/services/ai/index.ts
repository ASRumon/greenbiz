import { getAiKeys } from "../../lib/env";
import { aiUnavailable } from "../../lib/errors";
import { DEFAULT_GEMINI_MODEL, makeGemini } from "./gemini";
import { DEFAULT_GROQ_MODEL, makeGroq } from "./groq";
import { DEFAULT_OPENROUTER_MODEL, makeOpenRouter } from "./openrouter";
import { extractJson, type AiProvider, type CompleteOpts } from "./provider";

export type { AiProvider, CompleteOpts } from "./provider";
export { extractJson } from "./provider";

/**
 * Builds the provider chain for this request.
 *
 * Order is Gemini -> Groq -> OpenRouter. Providers with no configured key are
 * skipped entirely, so a deployment with only a Gemini key makes exactly one
 * network call. Extra Gemini keys (GEMINI_API_KEY_2/3) are appended after the
 * primary as rotation targets, which matters on the free tier where a single
 * key is rate limited quickly.
 *
 * Built per request rather than cached in a module-level array: a Worker
 * isolate is reused across requests, and a cached chain would pin one request's
 * keys for the lifetime of the isolate.
 */
export function buildProviderChain(env: Env): AiProvider[] {
	const keys = getAiKeys(env);
	const geminiModel = env.AI_MODEL ?? DEFAULT_GEMINI_MODEL;

	const chain: AiProvider[] = [];

	for (const [index, key] of keys.gemini.entries()) {
		// Label rotation keys distinctly so logs show which one was tried.
		const label = index === 0 ? `gemini:${geminiModel}` : `gemini#${index + 1}:${geminiModel}`;
		chain.push(makeGemini(key, geminiModel, label));
	}

	if (keys.groq) chain.push(makeGroq(keys.groq, DEFAULT_GROQ_MODEL));
	if (keys.openRouter) chain.push(makeOpenRouter(keys.openRouter, DEFAULT_OPENROUTER_MODEL));

	return chain;
}

/**
 * Runs a completion against the first provider that succeeds.
 *
 * Failures are logged with the provider name and message only - never the key,
 * never the request URL (the Gemini URL embeds the key), never the full prompt
 * (the prompt contains the shop's transaction data).
 */
export async function aiComplete(env: Env, opts: CompleteOpts): Promise<string> {
	const chain = buildProviderChain(env);
	if (chain.length === 0) {
		throw aiUnavailable(
			"No AI provider is configured. Set GEMINI_API_KEY (or GROQ_API_KEY / OPENROUTER_API_KEY) as a Worker secret.",
		);
	}

	let lastError: unknown;

	for (const provider of chain) {
		try {
			return await provider.complete(opts);
		} catch (error) {
			lastError = error;
			const message = error instanceof Error ? error.message : "unknown error";
			console.warn(`AI provider ${provider.name} failed: ${message}`);
		}
	}

	const finalMessage = lastError instanceof Error ? lastError.message : "unknown error";
	throw aiUnavailable(`All ${chain.length} AI provider(s) failed. Last error: ${finalMessage}`);
}

/**
 * Completion that must return a JSON object.
 *
 * Returns the parsed value as `unknown` - callers validate with Zod rather than
 * trusting the model's output shape.
 */
export async function aiCompleteJson(env: Env, opts: CompleteOpts): Promise<unknown> {
	const raw = await aiComplete(env, { ...opts, json: true });
	return extractJson<unknown>(raw);
}
