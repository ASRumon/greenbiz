# GreenBiz Architecture

An Android app for small business owners in Bangladesh and India that turns
mobile-money SMS into structured records, and turns those records into a credit
profile.

---

## 1. The pipeline

The whole product is one pipeline. Everything else is plumbing around it.

```
 ┌────────────────────────────────────────────────────────────────────┐
 │ Android device                                                      │
 │                                                                     │
 │  Device SMS inbox                                                   │
 │         │                                                           │
 │         │  1. filter to known sender IDs (16247, 16248, 16216,      │
 │         │     VM-HDFCBK, ...) — done ON THE PHONE                   │
 │         ▼                                                           │
 │  SmsInboxScan  ──  personal messages are dropped here and never     │
 │         │          leave the device                                 │
 │         │                                                           │
 │         │  2. POST /api/shops/:id/sms/bulk  (idempotent)             │
 └─────────┼───────────────────────────────────────────────────────────┘
           ▼
 ┌────────────────────────────────────────────────────────────────────┐
 │ Cloudflare Worker                                                   │
 │                                                                     │
 │  Tier 1: regex patterns  ──► hit ──┐                                │
 │    bkash / nagad / rocket / upi    │                                │
 │    (parse_source = 'regex')        │                                │
 │         │ miss                     │                                │
 │         ▼                          │                                │
 │  Tier 2: aiComplete()              │                                │
 │    Gemini → Groq → OpenRouter      │                                │
 │    (parse_source = 'llm')          │                                │
 │         │ confidence < 0.7         │                                │
 │         ▼                          │                                │
 │    parse_status = 'pending'        │   (no transaction is booked      │
 │    nothing is booked               │    from a guess)                 │
 │                                    ▼                                │
 │                            ┌───────────────┐                        │
 │                            │ sms_messages  │  raw text + provider +  │
 │                            │               │  parse_status +         │
 │                            │               │  raw_extract (JSON)     │
 │                            └───────┬───────┘                        │
 │                                    │ 1:1 when parsed                │
 │                                    ▼                                │
 │                            ┌───────────────┐                        │
 │                            │ transactions  │  direction,             │
 │                            │               │  amount_minor,          │
 │                            │               │  currency,              │
 │                            │               │  counterparty,          │
 │                            │               │  reference (TrxID)      │
 │                            └───────┬───────┘                        │
 │                                    │                                │
 │              rule-based scoring over the last 90 days               │
 │                                    ▼                                │
 │                            ┌─────────────────┐                      │
 │                            │ credit_profiles │  score 0-100 +       │
 │                            │                 │  4 weighted factors  │
 │                            └───────┬─────────┘                      │
 │                                    │                                │
 │                                    ▼                                │
 │        matchPlans() — eligibility + EMI + revenue cover             │
 │                                    │                                │
 │                                    ▼                                │
 │        GET /shops/:id/matched-plans → { matches, capacity }         │
 └────────────────────────────────────────────────────────────────────┘
```

### Why each step is where it is

**The sender filter runs on the device, not the server.** Uploading the whole
inbox and filtering server-side would mean personal messages, one-time
passwords, and bank OTPs leave the phone and get stored. Filtering first means
they never do. This is the single most important privacy decision in the system,
and it is enforced by code the user can read: `Env.isPaymentSender`.

**Parsing is two-tier, regex first.** Mobile money SMS templates are highly
regular, so a regex handles the overwhelming majority — the smoke test shows
7/7 real templates parsed at tier 1 with zero LLM calls. Only unrecognised
messages reach a model. That keeps cost, latency, and the number of messages
sent to a third party to a minimum.

**A low-confidence parse does not become a transaction.** If the model returns
`confidence < 0.7`, the SMS is stored as `pending` with the guess kept in
`raw_extract` for review, and no money is booked. A wrong number in a ledger is
worse than a missing one, because the owner will trust it.

**The credit profile is derived, not entered.** It is computed from
`transactions` and cached in `credit_profiles` so reads are cheap. It is
recomputed on every write that could change it (SMS ingest, transaction
create/update/delete) so the Finance tab is never stale after the flagship flow.

---

## 2. Why D1 / SQLite

| Consideration | Why D1 wins here |
|---|---|
| **Data shape** | One shop owner's data is a few thousand rows. There is no scale problem to solve. |
| **Cost** | D1's free tier covers a hackathon demo and a pilot with room to spare. |
| **Consistency** | The SMS ingest path is an idempotent upsert. A single-writer SQLite database makes that a `UNIQUE` index rather than distributed-systems work. |
| **Edge latency** | Reading from the same region as the Worker keeps API calls fast on 3G, which is the realistic network for the target user. |
| **Ops** | No connection pooling, no migrations server, no VPC. `wrangler d1 migrations apply`. |

The tradeoff: no extensions, no `gen_random_uuid()`, no `pgcrypto`, a 100
bound-parameter cap per statement, and one write region. All four are
acceptable for a per-shop ledger, and each is handled explicitly (UUIDs are
generated in the Worker; `chunkForInsert` respects the parameter cap).

---

## 3. Money is always an integer

Every amount is an integer in **minor units** — poisha for BDT, paisa for INR.
`150000` means Tk 1,500.00. There is no float anywhere in the money path, on
either side of the wire.

This is not stylistic. `1699.05 * 100` is `169905.00000000003` in IEEE-754.
Rounding hides that on one row; across a ledger it does not stay hidden. So the
conversion is done by string-splitting the integer and fraction parts:

```ts
// greenbiz/src/services/smsParser/patterns/shared.ts
const match = /^(\d+)(?:\.(\d{1,2}))?$/.exec(raw);
return Number(match[1]) * 100 + Number((match[2] ?? "").padEnd(2, "0"));
```

```dart
// lib/core/money.dart  (the same approach on the client)
final fraction = int.tryParse(fractionText.padRight(2, '0')) ?? 0;
return whole * 100 + fraction;
```

Both sides reject a third decimal place instead of truncating it: `1.005` is not
representable in paisa, so it is an error rather than a silently wrong number.

The only places a float appears are `interest_rate_min/max` (a percentage, not
money) and `stock_quantity` (which legitimately supports 2.5 kg).

---

## 4. How the plan matcher ranks

`greenbiz/src/services/planMatcher.ts` loads the active loan and working-capital
rows, computes the shop's average monthly business revenue over the same 90-day
window as the credit score, and evaluates every product through
`src/services/loanMath.ts`.

For a term loan the instalment is standard amortisation:
$EMI = P \cdot r \cdot (1+r)^n / ((1+r)^n - 1)$, where $r$ is the annual rate
divided by 12. A revolving or interest-only line services interest only; its
affordability is still tested as if the principal were repaid over the renewal
period, otherwise every cash credit would look 30× affordable.

The owner's rule is the priority band:

| Monthly revenue ÷ instalment | Priority |
|---|---|
| **≥ 2.0×** | High priority |
| 1.3× – 2.0× | Good fit |
| < 1.3× | Stretch |
| no published rate | Terms on request |

The headline capacity answer uses the same rule from the other direction: the
instalment is capped at **50% of average monthly revenue**, and the largest
principal that fits inside a real product band is returned as
`capacity.suggestedAmountMinor`. High-priority term plans are preferred for the
headline number; if no product can be sized yet, a 12% / 36-month benchmark is
returned and labelled `indicative_benchmark`.

Each match carries `fitScore`, `priority`, `emiMinor`,
`suggestedAmountMinor`, `affordabilityRatio`, `reasons[]`, `requirements[]`
and `warnings[]`, so the Finance card can explain every ranking. Collateral,
CIB history and documents are listed as requirements rather than silently
filtered, because the app cannot verify them.

**Catalogue data.** The directory is the 39-product Bangladeshi SME comparison
table supplied on 2026-10-18: BRAC Bank, Sonali Bank, EBL, DBBL, Jamuna Bank,
Dhaka Bank, Prime Bank and The City Bank. `last_verified_at` records that date.
The app calls every EMI an estimate; the lender decides the final amount.

---

## 5. Request lifecycle

```
Request
  │
  ├─ logger()
  ├─ cors("/api/*")            credentials: false (bearer token, not cookies)
  ├─ GET /api/health           answered BEFORE attachDb, so a missing D1
  │                            binding is reported rather than thrown
  ├─ attachDb                  builds the Drizzle client from this request's env
  │
  ├─ route module
  │    ├─ requireAuth          Authorization: Bearer → verify HS256 → userId
  │    ├─ parseJsonBody/Query  Zod; throws VALIDATION_ERROR with field paths
  │    ├─ requireOwnedShop     ownership check, 404 (not 403) on mismatch
  │    └─ handler              Drizzle only — no raw SQL strings
  │
  └─ onError                   { error: { code, message, details? } }
                               AppError → its own status; anything else → 500
                               with a generic message (never a stack or SQL)
```

Two invariants worth stating explicitly:

- **Unknown shop and someone-else's-shop both return 404.** A 403 would confirm
  the id exists, which is a free enumeration oracle.
- **No handler touches `env.DB` directly.** `attachDb` runs first, so the DB
  client is built per request from the per-request `env`.

---

## 6. Worker module map

```
greenbiz/src/
├── index.ts                   Hono app: middleware order, route mounting
├── routes/                    one file per resource, Zod schemas inline
│   ├── auth.ts                register (auto-creates a shop), login, me
│   ├── shops.ts               CRUD + explicit child deletes in a db.batch
│   ├── products.ts            /shops/:id/products and /products/:id
│   ├── sms.ts                 bulk upload, list, reparse
│   ├── transactions.ts        CRUD + ranges; recomputes the score on write
│   ├── credit.ts              read, recompute, matched-plans, formula
│   ├── plans.ts               public directory with an amount-overlap filter
│   ├── institutions.ts        public directory with active plan counts
│   ├── ai.ts                  recommend, parse-sms, status
│   └── admin.ts               POST /seed, guarded by ADMIN_TOKEN
├── db/
│   ├── schema.ts              Drizzle schema; all 9 tables + inferred types
│   ├── client.ts              createDb(d1) — one client per request
│   └── migrations/            generated by drizzle-kit, applied by Wrangler
├── middleware/
│   ├── auth.ts                requireAuth, requireAdmin (constant-time)
│   └── error.ts               attachDb, onError, notFoundHandler
├── services/
│   ├── auth.ts                bcrypt + jose; burns time on unknown users
│   ├── shopAccess.ts          requireOwnedShop / requireOwnedProduct
│   ├── smsIngest.ts           shared by bulk upload and reparse
│   ├── smsParser/             two-tier parser + 4 provider pattern files
│   ├── creditScore.ts         pure scoring function + upsert
│   ├── loanMath.ts            pure EMI / affordability / priority maths
│   ├── planMatcher.ts         eligibility + EMI + revenue-cover ranking
│   └── ai/                    provider.ts, gemini.ts, groq.ts,
│                              openrouter.ts, index.ts (the chain)
└── lib/
    ├── env.ts                 Zod-validated secrets, AI key rotation
    ├── errors.ts              AppError + the one error shape
    ├── context.ts             AppBindings, currentUserId
    ├── validate.ts            parseJsonBody / parseQuery / parseParams
    ├── schemas.ts             shared Zod primitives
    └── d1Limits.ts            the 100-bound-parameter chunking helper
```

---

## 7. AI fallback chain

```
GEMINI_API_KEY ─► GEMINI_API_KEY_2 ─► GEMINI_API_KEY_3 ─► GROQ ─► OPENROUTER
   (primary)          (rotation)           (rotation)      (fallback 1)
```

The chain is built per request, not cached in a module variable: a Worker
isolate is reused across requests, and a cached chain would pin the first
request's keys for the isolate's lifetime.

Three rules hold everywhere in `services/ai/`:

1. **Keys never leave the Worker.** The client only ever receives text.
2. **The Gemini request URL is never logged or included in an error.** The key
   travels as a `?key=` query parameter, so a URL in a log line is a leaked
   credential. `assertOk` reports the status code and a truncated body only.
3. **Prompts are not logged.** The advice prompt contains the shop's revenue
   figures; the SMS prompt contains message text.

Extra Gemini keys exist because the free tier rate-limits per key per minute,
which is easy to hit during a live demo.

---

## 8. Client architecture

```
lib/
├── main.dart                  loads prefs → ProviderScope → MaterialApp
├── core/
│   ├── env.dart               API base URL + the sender allow-list
│   ├── api_client.dart        Dio + bearer interceptor + error normalisation
│   ├── money.dart             integer money formatting and parsing
│   ├── providers.dart         DI wiring (prefs, Dio, 7 services)
│   ├── router.dart            routes + the bootstrap gate
│   └── theme.dart             one seeded Material 3 scheme
├── features/
│   ├── auth/                  controller + login/register
│   ├── home_shell.dart        the 3-tab bottom navigation
│   ├── inventory/             controller, screen, form sheet, detail
│   ├── finance/               controller, screen, 4 card widgets
│   └── profile/               controller, screen, SMS permission card
├── models/                    6 hand-written JSON models
├── services/                  7 thin API wrappers
└── widgets/common.dart        AppCard, EmptyState, ErrorView, AsyncSection
```

**State lives in Riverpod `Notifier`s, and derived data lives in
`FutureProvider`s that watch the active shop.** Switching shops invalidates
everything downstream automatically — there is no manual cache-busting code
anywhere in the app.

**Mutating actions invalidate rather than patch.** After adding a product, the
list provider is invalidated and refetched. The screen therefore always shows
what the server actually stored, instead of a local guess that can drift.

**`AsyncSection` exists so loading and error states cannot be forgotten.** Every
async card renders through it, which is why no screen can show a spinner
forever or a raw exception string.
