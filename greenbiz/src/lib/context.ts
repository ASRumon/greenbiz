import type { Context } from "hono";
import { unauthorized } from "./errors";

/**
 * Hono environment shared by the whole app.
 *
 * `Bindings` comes from the generated `Env` in worker-configuration.d.ts,
 * augmented with secrets in src/lib/env.ts.
 *
 * `Variables` is what middleware puts on `c.get(...)`:
 *   userId - set by requireAuth, guaranteed non-null inside protected routes.
 */
export type AppBindings = {
	Bindings: Env;
	Variables: {
		userId: string;
	};
};

export type AppContext = Context<AppBindings>;

/**
 * `c.get("userId")` is typed as `string`, but a route mounted without
 * `requireAuth` would get `undefined` at runtime. This accessor turns that
 * mistake into a loud 401 instead of a silent `WHERE owner_id = undefined`.
 */
export function currentUserId(c: AppContext): string {
	const userId = c.get("userId");
	if (!userId) {
		throw unauthorized();
	}
	return userId;
}
