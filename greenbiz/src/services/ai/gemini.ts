import {
	DEFAULT_MAX_TOKENS,
	assertOk,
	fetchWithTimeout,
	type AiProvider,
	type CompleteOpts,
} from "./provider";

/**
 * Google Gemini - primary provider.
 *
 * Uses the REST endpoint directly rather than `@google/generative-ai`: that
 * package is deprecated upstream and pulls a large SDK into the Worker bundle
 * for what is a single POST request. The REST shape is stable and documented.
 *
 * The API key travels as a `?key=` query parameter, so this module must never
 * surface the request URL in an error or a log line.
 */

const API_ROOT = "https://generativelanguage.googleapis.com/v1beta/models";

/** Fast and cheap; override with the AI_MODEL var if a different model is wanted. */
export const DEFAULT_GEMINI_MODEL = "gemini-2.5-flash";

interface GeminiResponse {
	candidates?: {
		content?: { parts?: { text?: string }[] };
		finishReason?: string;
	}[];
	promptFeedback?: { blockReason?: string };
}

/**
 * Only Gemini 2.5 Flash/Lite accept `thinkingBudget: 0`. Other models either
 * do not know the field or require a minimum thinking budget, and would reject
 * the whole request.
 */
function supportsThinkingBudget(model: string): boolean {
	return model.includes("2.5") && (model.includes("flash") || model.includes("lite"));
}

export function makeGemini(
	apiKey: string,
	model = DEFAULT_GEMINI_MODEL,
	/** Label used in logs, so rotation keys are distinguishable from the primary. */
	label = `gemini:${model}`,
): AiProvider {
	const providerName = label;

	return {
		name: providerName,

		async complete(opts: CompleteOpts): Promise<string> {
			const response = await fetchWithTimeout(`${API_ROOT}/${model}:generateContent?key=${apiKey}`, {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({
					systemInstruction: { parts: [{ text: opts.system }] },
					contents: [{ role: "user", parts: [{ text: opts.user }] }],
					generationConfig: {
						maxOutputTokens: opts.maxTokens ?? DEFAULT_MAX_TOKENS,
						temperature: opts.json ? 0 : 0.4,
						...(opts.json ? { responseMimeType: "application/json" } : {}),
						// Gemini 2.5 Flash/Lite think before answering by default. That
						// thinking spends the same output budget as the answer, which is
						// how a short advice/JSON reply ended up truncated mid-sentence.
						...(supportsThinkingBudget(model)
							? { thinkingConfig: { thinkingBudget: 0 } }
							: {}),
					},
				}),
			});

			await assertOk(response, providerName);

			const payload = (await response.json()) as GeminiResponse;

			if (payload.promptFeedback?.blockReason) {
				throw new Error(`${providerName} blocked the prompt (${payload.promptFeedback.blockReason})`);
			}

			const text = payload.candidates?.[0]?.content?.parts
				?.map((part) => part.text ?? "")
				.join("")
				.trim();

			if (!text) {
				throw new Error(`${providerName} returned an empty completion`);
			}
			return text;
		},
	};
}
