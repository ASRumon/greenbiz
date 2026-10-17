/**
 * Provider-agnostic LLM interface.
 *
 * Every provider returns a plain string. Callers that need structured output
 * pass `json: true` and run the result through `extractJson`, so no provider
 * specifics leak past this boundary.
 */

export interface CompleteOpts {
	/** Behavioural instructions. */
	system: string;
	/** The actual task input. */
	user: string;
	/** Ask the provider for a JSON object response where supported. */
	json?: boolean;
	/** Soft cap on output length. */
	maxTokens?: number;
}

export interface AiProvider {
	readonly name: string;
	complete(opts: CompleteOpts): Promise<string>;
}

/**
 * Default output ceiling.
 *
 * Generous on purpose: Gemini counts thinking tokens against this budget, and a
 * truncated JSON object is worse than a slightly costlier reply. JSON answers
 * from this app are still only a few hundred tokens.
 */
export const DEFAULT_MAX_TOKENS = 4096;

/** Give up on a slow provider and move to the next one in the chain. */
export const REQUEST_TIMEOUT_MS = 20_000;

/**
 * fetch with a hard timeout.
 *
 * NOTE: the request URL for Gemini carries the API key as a query parameter.
 * Never include `response.url`, the request URL, or the raw fetch error in a
 * thrown message or a log line — the key would end up in Cloudflare's log
 * output. Only the status code and a truncated body excerpt are safe.
 */
export async function fetchWithTimeout(
	url: string,
	init: RequestInit,
): Promise<Response> {
	try {
		return await fetch(url, { ...init, signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) });
	} catch (error) {
		const reason = error instanceof Error ? error.name : "unknown";
		throw new Error(`Request failed (${reason})`);
	}
}

/** Reads a response body, truncating it so a 500-page error cannot fill the logs. */
async function readErrorBodyExcerpt(response: Response): Promise<string> {
	try {
		const text = await response.text();
		return text.slice(0, 300);
	} catch {
		return "<unreadable body>";
	}
}

export async function assertOk(response: Response, providerName: string): Promise<void> {
	if (response.ok) return;
	const excerpt = await readErrorBodyExcerpt(response);
	throw new Error(`${providerName} returned HTTP ${response.status}: ${excerpt}`);
}

/**
 * Extracts a JSON value from a model response.
 *
 * Models wrap JSON in ```json fences or add a sentence of preamble even when
 * told not to. This strips fences, then falls back to slicing from the first
 * brace to the last, which recovers a clean object from noisy output.
 */
export function extractJson<T>(raw: string): T {
	const withoutFences = raw
		.replace(/^\s*```(?:json)?/i, "")
		.replace(/```\s*$/, "")
		.trim();

	const candidates = [withoutFences];

	const firstBrace = withoutFences.indexOf("{");
	const lastBrace = withoutFences.lastIndexOf("}");
	if (firstBrace !== -1 && lastBrace > firstBrace) {
		candidates.push(withoutFences.slice(firstBrace, lastBrace + 1));
	}

	for (const candidate of candidates) {
		try {
			// `JSON.parse` returns `any`; narrowing through unknown keeps the
			// value honest and forces callers to validate with Zod.
			return JSON.parse(candidate) as T;
		} catch {
			continue;
		}
	}

	throw new Error("Model response did not contain valid JSON");
}
