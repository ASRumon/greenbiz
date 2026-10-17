import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { adminRoutes } from "./routes/admin";
import { aiRoutes } from "./routes/ai";
import { authRoutes } from "./routes/auth";
import { creditRoutes } from "./routes/credit";
import { institutionRoutes } from "./routes/institutions";
import { planRoutes } from "./routes/plans";
import { productRoutes } from "./routes/products";
import { saleRoutes } from "./routes/sales";
import { shopRoutes } from "./routes/shops";
import { smsRoutes } from "./routes/sms";
import { transactionRoutes } from "./routes/transactions";
import type { AppBindings } from "./lib/context";
import { hasAnyAiProvider, requireDb } from "./lib/env";
import { attachDb, notFoundHandler, onError } from "./middleware/error";

/**
 * GreenBiz API - SME Finance Copilot.
 *
 * Everything lives under /api. Every other path is answered by the static
 * assets in ./public (see `assets` in wrangler.jsonc), which is why there is no
 * catch-all handler here: the assets binding serves first, and this Worker only
 * sees paths that are not files on disk.
 */
const app = new Hono<AppBindings>();

app.use("*", logger());

/**
 * CORS is opened only for the API surface.
 *
 * A Flutter Android client does not need CORS at all, but a browser-based demo
 * does. `credentials: false` because auth is a bearer token, not a cookie, so
 * no ambient credential can be replayed cross-origin.
 */
app.use(
	"/api/*",
	cors({
		origin: "*",
		allowMethods: ["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
		allowHeaders: ["Content-Type", "Authorization"],
		credentials: false,
		maxAge: 86400,
	}),
);

app.onError(onError);
app.notFound(notFoundHandler);

/* -------------------------------------------------------------------------- */
/* Health                                                                      */
/* -------------------------------------------------------------------------- */

app.get("/api/health", (c) => {
	// Verifies the D1 binding actually resolves, instead of reporting healthy for
	// a Worker that cannot reach its database.
	let databaseOk = true;
	try {
		requireDb(c.env);
	} catch {
		databaseOk = false;
	}

	return c.json({
		ok: databaseOk,
		service: "greenbiz-api",
		environment: c.env.ENVIRONMENT ?? "unknown",
		database: databaseOk ? "bound" : "missing",
		// Boolean only. Never the provider name, never any part of a key.
		aiConfigured: hasAnyAiProvider(c.env),
		time: new Date().toISOString(),
	});
});

/* -------------------------------------------------------------------------- */
/* API routes                                                                  */
/* -------------------------------------------------------------------------- */

// attachDb runs after the health check, so /api/health can *report* a missing
// binding rather than 500ing on it.
app.use("/api/*", attachDb);

app.route("/api/auth", authRoutes);
app.route("/api/shops", shopRoutes);
app.route("/api/institutions", institutionRoutes);
app.route("/api/ai", aiRoutes);
app.route("/api/admin", adminRoutes);

// These modules each serve more than one path family, so they are mounted at
// /api rather than under a single prefix:
//   products     -> /api/shops/:shopId/products, /api/products/:id
//   sales        -> /api/shops/:shopId/sales
//   sms          -> /api/shops/:shopId/sms, /api/sms/:id/reparse
//   transactions -> /api/shops/:shopId/transactions, /api/transactions/:id
//   credit       -> /api/shops/:shopId/credit, /api/shops/:shopId/matched-plans
//   plans        -> /api/plans, /api/plans/:id
app.route("/api", productRoutes);
app.route("/api", saleRoutes);
app.route("/api", smsRoutes);
app.route("/api", transactionRoutes);
app.route("/api", creditRoutes);
app.route("/api", planRoutes);

export default app;
