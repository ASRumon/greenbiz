import type { Context } from "hono";
import { createMiddleware } from "hono/factory";
import type { AppBindings } from "../lib/context";
import { AppError } from "../lib/errors";
import { ConfigError } from "../lib/env";
import { createDb, type Database } from "../db/client";
import { requireDb } from "../lib/env";

declare module "hono" {
	interface ContextVariableMap {
		userId: string;
		db: Database;
	}
}

/**
 * Builds the Drizzle client for this request and stashes it on the context.
 * Runs before any route handler, so handlers never touch `env.DB` directly.
 */
export const attachDb = createMiddleware<AppBindings>(async (c, next) => {
	c.set("db", createDb(requireDb(c.env)));
	await next();
});

/**
 * Terminal error handler.
 *
 * Guarantees the `{ error: { code, message, details? } }` contract for every
 * failure, including ones thrown by Zod, Drizzle, or an unexpected bug.
 *
 * Deliberately does NOT return `err.stack` or raw driver messages to the
 * client: D1 errors can embed the failing SQL, and SQL can embed user data.
 * The full error is logged server-side only.
 */
export function onError(err: Error, c: Context<AppBindings>): Response {
	if (err instanceof AppError) {
		// Expected, actionable failures: safe to log at warn and return verbatim.
		console.warn(`[${err.code}] ${c.req.method} ${c.req.path}: ${err.message}`);
		return err.toResponse();
	}

	if (err instanceof ConfigError) {
		console.error(`[CONFIG_ERROR] ${c.req.method} ${c.req.path}: ${err.message}`);
		return Response.json(
			{
				error: {
					code: "CONFIG_ERROR",
					message: err.message,
				},
			},
			{ status: 500 },
		);
	}

	console.error(`[INTERNAL] ${c.req.method} ${c.req.path}:`, err.message, err.stack);
	return Response.json(
		{
			error: {
				code: "INTERNAL",
				message: "Something went wrong. Please try again.",
			},
		},
		{ status: 500 },
	);
}

/** Uniform 404 for unknown routes, matching the error contract. */
export const notFoundHandler = (c: Context<AppBindings>) =>
	Response.json(
		{
			error: {
				code: "NOT_FOUND",
				message: `No route matches ${c.req.method} ${new URL(c.req.url).pathname}`,
			},
		},
		{ status: 404 },
	);
