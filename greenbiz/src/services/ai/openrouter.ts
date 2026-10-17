import {
	DEFAULT_MAX_TOKENS,
	assertOk,
	fetchWithTimeout,
	type AiProvider,
	type CompleteOpts,
} from "./provider";

/**
 * OpenRouter - second fallback.
 *
 * OpenAI-compatible, and the last link in the chain: it fronts many models, so
 * it is the most likely of the three to still answer when the others are rate
 * limited or down.
 */

const ENDPOINT = "https://openrouter.ai/api/v1/chat/completions";

export const DEFAULT_OPENROUTER_MODEL = "meta-llama/llama-3.3-70b-instruct";

interface ChatCompletionResponse {
	choices?: { message?: { content?: string | null } }[];
}

export function makeOpenRouter(apiKey: string, model = DEFAULT_OPENROUTER_MODEL): AiProvider {
	const providerName = `openrouter:${model}`;

	return {
		name: providerName,

		async complete(opts: CompleteOpts): Promise<string> {
			const response = await fetchWithTimeout(ENDPOINT, {
				method: "POST",
				headers: {
					"Content-Type": "application/json",
					Authorization: `Bearer ${apiKey}`,
					// OpenRouter uses these for attribution only; no user data.
					"HTTP-Referer": "https://greenbiz.app",
					"X-Title": "GreenBiz SME Finance Copilot",
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
