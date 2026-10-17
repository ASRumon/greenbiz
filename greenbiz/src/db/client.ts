import { drizzle } from "drizzle-orm/d1";
import * as schema from "./schema";

/**
 * Drizzle client factory.
 *
 * One client per request, built from the request's `env` — never a module-level
 * singleton, because bindings are scoped to the request in Workers and a cached
 * client would leak the first request's DB handle into later ones.
 */
export type Database = ReturnType<typeof createDb>;

export function createDb(d1: D1Database) {
	return drizzle(d1, { schema });
}

export { schema };
