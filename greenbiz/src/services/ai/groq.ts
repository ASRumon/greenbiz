import {
	DEFAULT_MAX_TOKENS,
	assertOk,
	fetchWithTimeout,
	type AiProvider,
	type CompleteOpts,
} from "./provider";

/**
 * Groq - first fallback.
 *
 * OpenAI-compatible chat completions, so the request shape mirrors
 * openrouter.ts. Groq is the fallback of choice after Gemini because it is
 * fast and its JSON mode is reliable.
 */

const ENDPOINT = "https://api.groq.com/openai/v1/chat/completions";

export const DEFAULT_GROQ_MODEL = "llama-3.3-70b-versatile";

interface ChatCompletionResponse {
	choices?: { message?: { content?: string | null } }[];
}

export function makeGroq(apiKey: string, model = DEFAULT_GROQ_MODEL): AiProvider {
	const providerName = `groq:${model}`;

	return {
		name: providerName,

		async complete(opts: CompleteOpts): Promise<string> {
			const response = await fetchWithTimeout(ENDPOINT, {
				method: "POST",
				headers: {
					"Content-Type": "application/json",
					Authorization: `Bearer ${apiKey}`,
				},
				body: JSON.stringify({
					model,
					messages: [
						{ role: "system", content: opts.system },
						{ role: "user", content: opts.user },
					],
					max_tokens: opts.maxTokens ?? DEFAULT_MAX_TOKENS,
					temperature: opts.json ? 0 : 0.4,
					...(opts.json ? { response_format: { type: "json_object" } } : {}),
				}),
			});

			await assertOk(response, providerName);

			const payload = (await response.json()) as ChatCompletionResponse;
			const text = payload.choices?.[0]?.message?.content?.trim();

			if (!text) {
				throw new Error(`${providerName} returned an empty completion`);
			}
			return text;
		},
	};
}
