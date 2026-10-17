import type { Context } from "hono";
import { z } from "zod";
import type { AppBindings } from "./context";
import { badRequest } from "./errors";

/**
 * Every request input in this app goes through one of these helpers, so Zod
 * validation is structurally impossible to skip: handlers receive already-typed
 * data, never the raw body.
 */

/** Flattens Zod issues into a client-safe list. Never includes input values. */
export function formatIssues(error: z.ZodError): { path: string; message: string }[] {
	return error.issues.map((issue) => ({
		path: issue.path.map(String).join(".") || "(root)",
		message: issue.message,
	}));
}

/** Parses and validates a JSON request body. Malformed JSON is a 400, not a 500. */
export async function parseJsonBody<S extends z.ZodType>(
	c: Context<AppBindings>,
	schema: S,
): Promise<z.output<S>> {
	let raw: unknown;
	try {
		raw = await c.req.json();
	} catch {
		throw badRequest("Request body must be valid JSON");
	}

	const result = schema.safeParse(raw);
	if (!result.success) {
		throw badRequest("Request validation failed", formatIssues(result.error));
	}
	return result.data;
}

/**
 * Parses and validates the query string.
 *
 * All query values arrive as strings, so leaf schemas should use
 * `z.coerce.number()` / `z.coerce.boolean()` where a non-string is expected.
 */
export function parseQuery<S extends z.ZodType>(c: Context<AppBindings>, schema: S): z.output<S> {
	const result = schema.safeParse(c.req.query());
	if (!result.success) {
		throw badRequest("Invalid query parameters", formatIssues(result.error));
	}
	return result.data;
}

/** Parses and validates route params (e.g. `:id`, `:shopId`). */
export function parseParams<S extends z.ZodType>(c: Context<AppBindings>, schema: S): z.output<S> {
	const result = schema.safeParse(c.req.param());
	if (!result.success) {
		throw badRequest("Invalid path parameters", formatIssues(result.error));
	}
	return result.data;
}

/** Common path-parameter shapes. UUIDs are required because ids are generated app-side. */
export const idParam = <T extends string>(key: T) =>
	z.object({
		[key]: z.uuid(`${key} must be a valid UUID`),
	});
