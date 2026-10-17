# GreenBiz API

Cloudflare Worker backing the GreenBiz Android app. Hono + Drizzle + D1.

It ingests mobile-money SMS from bKash, Nagad, Rocket and UPI, turns them into
transactions, and derives a credit profile from them.

```
POST /api/shops/:id/sms/bulk  →  sms_messages  →  transactions  →  credit_profiles
                                  (tier 1 regex, tier 2 LLM)         (rule-based, 90 days)
```

---

## Deployed instance

The Worker is live at:

```
https://greenbiz.asrumon.workers.dev
```

```powershell
curl.exe https://greenbiz.asrumon.workers.dev/api/health
```

Populate it with a demo account and a believable three-month transaction history:

```powershell
powershell -File scripts/seed-demo-account.ps1
```

Run the app against it:

```powershell
flutter run -d android --dart-define=GREENBIZ_API_URL=https://greenbiz.asrumon.workers.dev/api
```

> The deployed instance has `JWT_SECRET` and `ADMIN_TOKEN` set, but no AI key, so
> `/api/health` reports `"aiConfigured": false`. Tier-1 regex parsing, the credit
> score, and the plan directory all work fully without it. To enable
> `/api/ai/recommend`, run `npx wrangler secret put GEMINI_API_KEY` and paste the
> key at the prompt — do not put it in a file that gets committed.

---

## Prerequisites

- **Node 20+**
- A **Cloudflare account** — only needed to deploy. Local development does not
  require one.
- `wrangler` is a dev dependency; use `npx wrangler` or the npm scripts.

---

## Setup

### 1. Install

```powershell
cd greenbiz
npm install
```

### 2. Create the D1 database

Only needed once, and only for deploying. **Local development works without
this step** because `wrangler dev` runs against a local SQLite file.

```powershell
npx wrangler d1 create greenbiz_db
```

That prints a `database_id`. Put it in `wrangler.jsonc`:

```jsonc
"d1_databases": [
  {
    "binding": "DB",
    "database_name": "greenbiz_db",
    "database_id": "<paste the id here>",
    "migrations_dir": "src/db/migrations",
    "remote": false     // true = `wrangler dev` uses the real remote DB
  }
]
```

The `DB` binding name matters: the code reads `env.DB`. `wrangler.jsonc` already
contains a working `database_id` for the `greenbiz_db` instance this project was
built against — replace it with your own if you are deploying to a different
account.

### 3. Secrets

Copy the example and fill it in. `.dev.vars` is gitignored.

```powershell
Copy-Item .dev.vars.example .dev.vars
```

| Key | Required | Purpose |
|---|---|---|
| `JWT_SECRET` | **yes** | HS256 session signing. Minimum 32 characters. |
| `ADMIN_TOKEN` | **yes** | Protects `POST /api/admin/seed`. Minimum 16 characters. |
| `GEMINI_API_KEY` | no | Primary AI provider. |
| `GEMINI_API_KEY_2`, `GEMINI_API_KEY_3` | no | Gemini rotation targets when the primary is rate limited. |
| `GROQ_API_KEY` | no | First fallback. |
| `OPENROUTER_API_KEY` | no | Second fallback. |
| `AI_MODEL` | no | Override the Gemini model. Default `gemini-2.5-flash`. |

Generate a secret:

```powershell
$b = New-Object 'System.Byte[]' 48
(New-Object System.Security.Cryptography.RNGCryptoServiceProvider).GetBytes($b)
-join ($b | ForEach-Object { $_.ToString('x2') })
```

For a deployed Worker, use secrets rather than `.dev.vars`:

```powershell
npx wrangler secret put JWT_SECRET
npx wrangler secret put ADMIN_TOKEN
npx wrangler secret put GEMINI_API_KEY
```

> With no AI key at all the API still works. Tier-1 regex parsing handles the
> known SMS templates, `/api/ai/recommend` returns a `503 AI_UNAVAILABLE` with a
> clear message, and `/api/health` reports `"aiConfigured": false`.
> There is no client-side fallback to a bundled key — keys never leave the Worker.

### 4. Migrate

```powershell
npm run db:migrate            # local SQLite
npm run db:migrate:remote     # the real D1 database
```

Migrations are authored by Drizzle Kit and applied by Wrangler:

```powershell
npm run db:generate           # after editing src/db/schema.ts
```

Drizzle never opens a connection — Wrangler owns the D1 lifecycle. That is why
`drizzle.config.ts` carries no credentials.

### 5. Seed the financial catalogue

```powershell
npm run seed                  # local
npm run seed:remote           # remote
```

This loads 14 institutions and 21 real products from `seed/institutions.json`
and `seed/plans.json` — BRAC Bank, IDLC, HDFC, SIDBI, MUDRA, LIC, and others.

Two equivalent paths exist, which is why the script is a two-step: `seed.ts`
generates `seed/seed.sql` from the JSON, and `wrangler d1 execute` applies it.
`POST /api/admin/seed` does the same thing over HTTP using the same JSON files
(imported at bundle time), so there is one source of truth.

> **The catalogue data is illustrative, not verified.** Institution names,
> websites and contact numbers are real; amount bands and rates are
> representative placeholders compiled from public sources. Every row is seeded
> with `last_verified_at = null`, and the API and UI surface that as "Terms not
> yet verified against the provider".

### 6. Run

```powershell
npm run dev          # http://127.0.0.1:8787
```

```powershell
curl.exe http://127.0.0.1:8787/api/health
```

```json
{
  "ok": true,
  "service": "greenbiz-api",
  "environment": "development",
  "database": "bound",
  "aiConfigured": true,
  "time": "2026-10-17T09:00:00.000Z"
}
```

---

## Pointing the Flutter app at this Worker

The app's default API base URL is `http://10.0.2.2:8787/api` — the Android
emulator's alias for the host machine's loopback interface. It works with no
configuration on an emulator.

On a **physical device**, `10.0.2.2` means nothing. Use your computer's LAN
address and make sure the phone is on the same network:

```powershell
ipconfig | Select-String "IPv4"     # e.g. 192.168.1.5

cd ..
flutter run -d android --dart-define=GREENBIZ_API_URL=http://192.168.1.5:8787/api
```

`wrangler dev` binds to `127.0.0.1` by default. To accept connections from the
phone, add `--ip 0.0.0.0`:

```powershell
npm run dev -- --ip 0.0.0.0
```

For a deployed Worker, point at it with HTTPS:

```powershell
flutter run -d android --dart-define=GREENBIZ_API_URL=https://greenbiz.<your-subdomain>.workers.dev/api
```

---

## API

All routes are under `/api`. Errors always have the same shape:

```json
{ "error": { "code": "VALIDATION_ERROR", "message": "…", "details": [ … ] } }
```

`details` is present only for validation failures and contains `{ path, message }`
entries.

### Public

| Method | Path | Notes |
|---|---|---|
| `GET` | `/api/health` | Bindings + AI availability. No secrets. |
| `GET` | `/api/institutions` | Lender directory with active plan counts. |
| `GET` | `/api/plans` | `?serviceType=&minAmount=&maxAmount=&limit=&offset=`. The amount filter is an **overlap** test. |
| `GET` | `/api/plans/:id` | Plan with its institution and decoded eligibility/fees. |
| `GET` | `/api/credit/formula` | The published scoring weights, so the score can be audited. |

### Auth

| Method | Path | Notes |
|---|---|---|
| `POST` | `/api/auth/register` | `{ fullName, username, email?, password, shopName?, businessType? }` → `{ token, user, shopId }`. **Creates a default shop.** |
| `POST` | `/api/auth/login` | `{ username, password }` — `username` accepts the email address too. → `{ token, user }` |
| `GET` | `/api/auth/me` | → `{ user, shops }` |

### Authenticated

`Authorization: Bearer <jwt>` on everything below.

| Method | Path |
|---|---|
| `GET`/`POST` | `/api/shops` |
| `GET`/`PATCH`/`DELETE` | `/api/shops/:id` |
| `GET`/`POST` | `/api/shops/:shopId/products` |
| `PATCH`/`DELETE` | `/api/products/:id` |
| `POST` | `/api/shops/:shopId/sales` |
| `POST` | `/api/shops/:shopId/sms/bulk` |
| `GET` | `/api/shops/:shopId/sms?limit=&offset=&parseStatus=` |
| `POST` | `/api/sms/:id/reparse` |
| `GET` | `/api/shops/:shopId/transactions?from=&to=&direction=&businessOnly=&limit=&offset=` |
| `POST` | `/api/shops/:shopId/transactions` |
| `PATCH`/`DELETE` | `/api/transactions/:id` |
| `GET` | `/api/shops/:shopId/credit` |
| `POST` | `/api/shops/:shopId/credit/recompute` |
| `GET` | `/api/shops/:shopId/matched-plans` |
| `POST` | `/api/ai/recommend` |
| `POST` | `/api/ai/parse-sms` |
| `GET` | `/api/ai/status` |

`POST /api/shops/:shopId/products`, `POST /api/shops/:shopId/transactions` and
`POST /api/shops/:shopId/sales` accept an optional client-generated `id` and
return the existing row when it is retried. That is what makes the app's offline
outbox safe to replay. Transactions carry `isBusiness`; pass
`?businessOnly=true` to a transaction list to get only business rows and their
totals (the cash-flow card does this).

`POST /api/admin/seed` is separate and requires `Authorization: Bearer <ADMIN_TOKEN>`.

**Offline-first contract.** Product creates, transaction creates and sales accept
an optional client-generated `id`. Repeating the request with the same id returns
the existing row instead of writing twice, so the app can retry a queued write
after a dropped response. Transactions carry `isBusiness` (default `true`) and
`paymentMethod` (`cash | bkash | nagad | rocket | upi | other`);
`businessOnly=true` on the list endpoint returns only business rows. Personal
rows stay in the ledger but are excluded from cash-flow totals and from the
credit score.

A sale also accepts `smsId` (the id of an imported payment message) and
`reference` (the mobile-money TrxID). When `smsId` matches an existing SMS
transaction for the **same payment**, the sale **merges into that row**: stock is
decremented, payment metadata is updated, and no second inflow is created. The
sale's client id is stored as `sale_id`, so a retry cannot decrement stock twice
even when the ledger row is the pre-existing SMS one.

"Same payment" allows for the cash-out charge. bKash/Nagad/Rocket/UPI charge
about **10-20 taka per thousand** (1-2%), and the customer usually adds it to
what they send, so the message and the bill differ by a few taka. A message
within `max(1 taka, 2% of the bill)` of the sale total links; anything further
away is treated as a different payment and the sale books its own row.
`src/lib/paymentTolerance.ts` is the source of that rule, mirrored in the app's
`lib/core/payment_tolerance.dart`.

### Examples

```powershell
# Register
$registered = Invoke-RestMethod -Method Post http://127.0.0.1:8787/api/auth/register `
  -ContentType "application/json" `
  -Body '{"fullName":"Karim Uddin","username":"karim","password":"correct-horse-battery"}'
$token = $registered.token
$shopId = $registered.shopId
$headers = @{ Authorization = "Bearer $token" }

# Parse a real bKash message without storing anything
Invoke-RestMethod -Method Post http://127.0.0.1:8787/api/ai/parse-sms -Headers $headers `
  -ContentType "application/json" `
  -Body '{"sender":"16247","body":"You have received Tk 1,500.00 from 01782665484. Fee Tk 0.00. Balance Tk 1,699.05. TrxID DJG73D7KLD at 16/10/2026 15:46"}'
```

```json
{
  "provider": "bkash",
  "currency": "BDT",
  "extract": {
    "direction": "in",
    "amountMinor": 150000,
    "counterparty": "01782665484",
    "reference": "DJG73D7KLD"
  },
  "parseSource": "regex",
  "parseStatus": "parsed",
  "tier": 1
}
```

`amountMinor: 150000` is Tk 1,500.00. **Every amount in this API is an integer in
the smallest unit.** `tier: 1` means a regex handled it, at no AI cost.

---

## SMS parsing

### Tier 1 — regex (`src/services/smsParser/patterns/`)

`bkash.ts`, `nagad.ts`, `rocket.ts`, `upi.ts`, plus Bangla-language bKash
templates. Patterns capture `(amount, counterparty, TrxID)` and apply a direction
per template.

Amounts are converted to minor units by splitting the integer and fraction parts
as strings, never via a float:

```ts
// "1,699.05" -> 169905, exactly
const match = /^(\d+)(?:\.(\d{1,2}))?$/.exec(raw.replace(/[,\s]/g, ""));
return Number(match[1]) * 100 + Number((match[2] ?? "").padEnd(2, "0"));
```

A third decimal place (`1.005`) is rejected rather than truncated — it is not
representable in paisa.

### Tier 2 — LLM fallback

Only for messages no pattern matched. The prompt asks for strict JSON
(`direction`, `amountMinor`, `currency`, `counterparty`, `reference`,
`confidence`), and the response is validated with Zod.

- `confidence >= 0.7` → `parse_status = 'parsed'`, a transaction is created.
- `confidence <  0.7` → `parse_status = 'pending'`. **No transaction is created**,
  and the model's guess is kept in `raw_extract` for review. A wrong number in a
  ledger is worse than a missing one.
- `{"error":"not_payment"}` → `parse_status = 'failed'`.

An obvious non-payment message from an unknown sender is rejected before the
model is called at all, so a personal SMS never reaches a provider.

`POST /api/sms/:id/reparse` re-runs the pipeline against stored text, so adding
an AI key or shipping a better regex can upgrade historical rows without asking
for the inbox again.

### Idempotency

`POST /api/shops/:shopId/sms/bulk` is idempotent on
`(shop_id, sender, body, received_at)`, enforced by a unique index and an
`ON CONFLICT DO NOTHING ... RETURNING`. An empty result *is* the duplicate
signal, so it is one round trip and race-free: two concurrent uploads of the same
inbox cannot both win.

---

## AI fallback chain

```
GEMINI_API_KEY → GEMINI_API_KEY_2 → GEMINI_API_KEY_3 → GROQ_API_KEY → OPENROUTER_API_KEY
```

Providers without a key are skipped. The chain is built per request, never cached
in a module variable. Keys are never logged, never returned, and never put in D1 —
`GET /api/ai/status` returns a boolean and nothing else.

> Gemini uses the REST endpoint via `fetch` rather than the
> `@google/generative-ai` package: that package is deprecated upstream and pulls
> a large SDK into the bundle for a single POST. Because the Gemini key travels
> as a `?key=` query parameter, the request URL is deliberately never included in
> an error message or a log line.

---

## Credit score

Rule-based, no ML, over the trailing 90 days.

```
score = 0.30·consistency + 0.25·volume + 0.25·stability + 0.20·activity
```

| Factor | Weight | What it measures |
|---|---|---|
| Consistency | 0.30 | How evenly inflow is spread week to week (coefficient of variation across weeks) |
| Volume | 0.25 | Average monthly inflow against a reference turnover (2,000,000 minor units) |
| Stability | 0.25 | Inverse of month-over-month volatility |
| Activity | 0.20 | Fraction of the 90 days with any recorded activity |

Output includes the four factor scores, the weighted contribution of each,
`monthlyRevenueAvgMinor`, `monthlyVolatility`, `transactionCount90d`, and
`riskFlags`: `no_activity`, `no_inflow`, `insufficient_history`, `low_activity`,
`high_volatility`, `revenue_declining`, `counterparty_concentration`.

`computeCredit` is a pure function — same input, same output, no clock, no
database — which is what makes it testable. It is recomputed automatically after
SMS ingest and after any transaction write, so the Finance tab is never stale.

`GET /api/credit/formula` publishes the weights so the score can be audited.

---

## Plan matching

`src/services/planMatcher.ts` ranks the 39 real Bangladeshi SME products against
the shop's average monthly business revenue (same 90-day window as the score).

- `src/services/loanMath.ts` computes the amortised EMI, interest-only cost,
  affordable principal, and the priority band. It is pure and unit-tested.
- **High priority** means monthly revenue is at least **2×** the instalment.
  **Good fit** is 1.3×–2×, **Stretch** is below 1.3×.
- `capacity.suggestedAmountMinor` caps the instalment at half of average monthly
  revenue and returns the largest principal inside a real product band. If no
  product can be sized, a 12% / 36-month benchmark is labelled as such.
- The response also carries `reasons[]`, `requirements[]` and `warnings[]`, so
  the app explains the ranking instead of showing a black-box score.

Collateral, CIB and documents are listed as requirements; the app does not claim
to verify them. Every EMI is an estimate, not an approval.

---

## Testing

```powershell
npx tsc --noEmit      # strict typecheck
npx vitest run        # 114 tests
```

Four suites:

- `test/smsParser.spec.ts` — amount exactness, digit normalisation, provider
  detection, every provider template, and the negative cases (personal messages,
  OTPs, promotions, unrepresentable amounts).
- `test/creditScore.spec.ts` — weights sum to 1, the 90-day window, outflows
  excluded, steadier revenue scoring higher, each risk flag, determinism, and the
  D1 parameter-cap chunking that the original seed insert violated.
- `test/loanMath.spec.ts` — amortised EMI, the affordable-principal inverse,
  interest-only revolving lines, the 2× / 1.3× priority bands, and product-band
  clamping.
- `test/index.spec.ts` — the HTTP contract: error shape, auth enforcement, and
  that the public routes really are public.

End to end against a running server (67 assertions covering the whole demo path):

```powershell
npm run dev
# in another terminal:
powershell -File scripts/smoke-test.ps1
# or against any deployment:
powershell -File scripts/smoke-test.ps1 -BaseUrl https://greenbiz.asrumon.workers.dev/api
```

There is also a demo-data provisioner:

```powershell
powershell -File scripts/seed-demo-account.ps1
```

It creates a user, a shop, 8 products, and roughly 50 mobile-money messages
spread across three months, then reports the resulting score. It goes through the
HTTP API rather than inserting SQL rows, so the data is created by exactly the
same code path a real user hits. It is idempotent: the account is reused, missing
products are the only ones added, SMS timestamps are anchored to UTC day
boundaries so the `(shop_id, sender, body, received_at)` index rejects repeats,
and manual entries are guarded by a marker note.

It registers an account, adds a product, uploads 8 real SMS templates (7 payments
and 1 deliberately personal message), and asserts: 7 parsed at tier 1, the
personal message excluded, the score recomputed, the credit factors summing to 1,
re-upload adding zero rows, another account unable to touch the shop, and a user
token rejected by the admin route.

---

## Deploy

```powershell
npx wrangler d1 migrations apply greenbiz_db --remote
npm run seed:remote
npx wrangler secret put JWT_SECRET
npx wrangler secret put ADMIN_TOKEN
npx wrangler secret put GEMINI_API_KEY
npm run deploy
```

Set `"remote": true` in `wrangler.jsonc` if you want `wrangler dev` to use the
production database — useful for debugging, dangerous for demo data.

---

## Project layout

See `docs/ARCHITECTURE.md` for the full module map and the reasoning behind each
boundary. `docs/SECURITY.md` covers data classification, permission tiers, and
the known gaps. `docs/DEMO_SCRIPT.md` is the five-minute walkthrough.

### `public/` — the browser dashboard

`public/index.html` is a self-contained single-page dashboard served at `/` by
the assets binding. It mirrors the app deliberately: the same three tabs
(Inventory, Finance, Profile), Sell and Payments pushed from their parent tab,
and the same screen titles, card names and field labels, so an owner who has used
one client already knows the other. It talks to the same `/api` routes and shares
the same rules — integer minor units, the ten-minute SMS suggestion window, and
the cash-out tolerance band (`src/lib/paymentTolerance.ts`).

Two details worth knowing before editing it:

- **Never compare `form.id`.** A control named `id` (the hidden product id) is
  exposed as a property on the form and shadows `form.id`, which silently
  disables `preventDefault` and lets the browser do a native GET submit. The
  submit dispatcher reads `form.getAttribute("id")` for exactly this reason.
- `public/_headers` sets a strict CSP (`form-action 'self'`, `frame-ancestors
  'none'`, no plugins) because the session token lives in `localStorage`. Keep
  all DOM text escaped through the `esc()` helper.

Copy lives in one place per screen: if a label changes in the Flutter app, change
it here too — `lib/features/**` is the source of truth for wording.
