import { defineConfig } from "drizzle-kit";

/**
 * Drizzle Kit is used ONLY to generate SQL migration files (`npm run db:generate`).
 *
 * Migrations are *applied* by Wrangler (`npm run db:migrate`), not by Drizzle,
 * because Wrangler owns the D1 database lifecycle (local Miniflare state and
 * remote Cloudflare state). That is also why no `dbCredentials` are needed
 * here: Drizzle never opens a connection.
 *
 * The `out` directory matches `d1_databases[0].migrations_dir` in wrangler.jsonc.
 */
export default defineConfig({
	schema: "./src/db/schema.ts",
	out: "./src/db/migrations",
	dialect: "sqlite",
	strict: true,
	verbose: true,
});
