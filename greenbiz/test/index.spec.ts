import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

/**
 * HTTP contract tests.
 *
 * These run inside workerd via the Cloudflare Vitest plugin, so they exercise
 * the real middleware chain and the real bindings from wrangler.jsonc.
 *
 * Deliberately limited to routes that do not read the database: this suite
 * asserts the *contract* — status codes, the error shape, auth enforcement,
 * and the absence of secret material in responses. The seeded-data path is
 * covered end to end by scripts/smoke-test.ps1, so a schema change cannot break
 * the contract suite and a contract change cannot be hidden by seeded data.
 */

describe("GET /api/health", () => {
	it("reports service status without requiring auth", async () => {
		const response = await SELF.fetch("https://example.com/api/health");
		expect(response.status).toBe(200);

		const body = (await response.json()) as Record<string, unknown>;
		expect(body.service).toBe("greenbiz-api");
		expect(body.ok).toBe(true);
		// If the D1 binding does not resolve, the Worker cannot serve anything.
		expect(body.database).toBe("bound");
		// A boolean is all the client is ever told about AI configuration.
		expect(typeof body.aiConfigured).toBe("boolean");
	});

	it("never exposes a secret", async () => {
		const response = await SELF.fetch("https://example.com/api/health");
		const raw = await response.text();

		expect(raw).not.toContain("GEMINI_API_KEY");
		expect(raw).not.toContain("GROQ_API_KEY");
		expect(raw).not.toContain("JWT_SECRET");
		expect(raw).not.toContain("ADMIN_TOKEN");
	});
});

describe("error contract", () => {
	it("returns { error: { code, message } } for an unknown route", async () => {
		const response = await SELF.fetch("https://example.com/api/does-not-exist");
		expect(response.status).toBe(404);

		const body = (await response.json()) as {
			error?: { code?: string; message?: string };
		};
		expect(body.error?.code).toBe("NOT_FOUND");
		expect(typeof body.error?.message).toBe("string");
	});

	it("returns 401 for a protected route with no token", async () => {
		const response = await SELF.fetch("https://example.com/api/auth/me");
		expect(response.status).toBe(401);

		const body = (await response.json()) as { error?: { code?: string } };
		expect(body.error?.code).toBe("UNAUTHORIZED");
	});

	it("guards the sale endpoint", async () => {
		const response = await SELF.fetch(
			"https://example.com/api/shops/00000000-0000-4000-8000-000000000000/sales",
			{
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({ items: [] }),
			},
		);
		expect(response.status).toBe(401);

		const body = (await response.json()) as { error?: { code?: string } };
		expect(body.error?.code).toBe("UNAUTHORIZED");
	});

	it("returns 401 for a malformed JWT", async () => {
		const response = await SELF.fetch("https://example.com/api/shops", {
			headers: { Authorization: "Bearer not.a.jwt" },
		});
		expect(response.status).toBe(401);
	});

	it("rejects a non-bearer Authorization header", async () => {
		const response = await SELF.fetch("https://example.com/api/shops", {
			headers: { Authorization: "Basic dXNlcjpwYXNz" },
		});
		expect(response.status).toBe(401);
	});

	it("rejects a bearer token with nothing after it", async () => {
		const response = await SELF.fetch("https://example.com/api/shops", {
			headers: { Authorization: "Bearer " },
		});
		expect(response.status).toBe(401);
	});
});

describe("input validation", () => {
	it("returns VALIDATION_ERROR with field paths for a bad register body", async () => {
		const response = await SELF.fetch("https://example.com/api/auth/register", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ fullName: "A", username: "x", password: "short" }),
		});

		expect(response.status).toBe(400);

		const body = (await response.json()) as {
			error?: { code?: string; details?: { path: string; message: string }[] };
		};
		expect(body.error?.code).toBe("VALIDATION_ERROR");
		expect(Array.isArray(body.error?.details)).toBe(true);
		// Every issue must name the offending field, or the client cannot
		// highlight it in the form.
		expect(body.error?.details?.every((issue) => issue.path.length > 0)).toBe(true);
	});

	it("returns 400 for a body that is not JSON", async () => {
		const response = await SELF.fetch("https://example.com/api/auth/login", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: "not json at all",
		});
		expect(response.status).toBe(400);
	});

	it("rejects an admin seed request without the admin token", async () => {
		const response = await SELF.fetch("https://example.com/api/admin/seed", {
			method: "POST",
		});
		expect(response.status).toBe(401);
	});

	it("rejects an admin seed request with a wrong token", async () => {
		const response = await SELF.fetch("https://example.com/api/admin/seed", {
			method: "POST",
			headers: { Authorization: "Bearer definitely-the-wrong-token" },
		});
		expect(response.status).toBe(401);
	});
});

describe("public directory", () => {
	it("never demands a token for the plan catalogue", async () => {
		const response = await SELF.fetch("https://example.com/api/plans");
		// A 200 is expected once migrations have run; the assertion that matters
		// here is that the route is not behind auth.
		expect(response.status).not.toBe(401);
		expect(response.status).not.toBe(403);
	});

	it("never demands a token for the institution directory", async () => {
		const response = await SELF.fetch("https://example.com/api/institutions");
		expect(response.status).not.toBe(401);
		expect(response.status).not.toBe(403);
	});

	it("serves the scoring formula so the score can be audited", async () => {
		const response = await SELF.fetch("https://example.com/api/credit/formula");
		expect(response.status).toBe(200);

		const body = (await response.json()) as {
			formula?: string;
			factors?: { weight: number }[];
		};
		expect(body.formula).toContain("0.30*consistency");
		// The published weights must sum to 1, or the formula in the docs is wrong.
		const total = body.factors?.reduce((sum, factor) => sum + factor.weight, 0) ?? 0;
		expect(Math.abs(total - 1)).toBeLessThan(0.0001);
	});
});
