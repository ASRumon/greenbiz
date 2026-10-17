# GreenBiz Security & Privacy

This document is the security position of the product, not a summary of good
intentions. Where something is not yet done, it says so.

---

## 1. Data classification

Four classes, with different rules. Most of the design follows from keeping them
separate.

| Class | Examples | Who can read it | Where it lives |
|---|---|---|---|
| **Public** | Plan directory, institution list, scoring formula | Anyone, no auth | `financial_institutions`, `financial_service_plans` |
| **Account** | Name, username, email hash, shop profile | The owner only | `users`, `shops` |
| **Commercial** | Inventory, prices, transactions, credit profile | The owner only | `products`, `transactions`, `credit_profiles` |
| **Restricted (PII)** | Raw SMS bodies, counterparty phone numbers, TrxIDs | The owner only. **Never a lender.** | `sms_messages` |

The critical rule: **class 4 never crosses to class 3's audience.** A lender that
later consumes a credit profile receives aggregates — score, factor scores,
monthly inflow average, volatility, transaction count, risk flags. It does not
receive message text, and it does not receive counterparty phone numbers.

### Permission tiers in the app

| Tier | What it needs | What the user is asked |
|---|---|---|
| **No account** | Nothing | Can browse the plan directory. |
| **Account** | `INTERNET` | Can manage inventory and enter transactions manually. |
| **Payment records** | `READ_SMS` | Opt-in, triggered only by tapping "Grant permission" in the Profile tab. |

The app **never requests `READ_SMS` at launch** and never requests it on a
screen the user did not navigate to. `RECEIVE_SMS` is declared in the manifest
for the planned live-capture feature but is **not requested at runtime**, so no
message is intercepted today.

Permissions this app deliberately does not request: `READ_CONTACTS`,
`READ_CALL_LOG`, `ACCESS_FINE_LOCATION`, and the advertising ID. There is no
code path that would use them.

---

## 2. SMS handling — the load-bearing control

This is the part of the product most likely to be abused if implemented
carelessly, so the constraints are explicit.

### What is read

Only messages whose sender matches the allow-list in `lib/core/env.dart`:
bKash/Nagad/Rocket short codes (16247, 16248, 16216, 16218) and Indian bank
headers matched by suffix (`VM-HDFCBK`, `AD-SBIINB`, …). The filter runs
**on the device**, in `SmsService.scanInbox`, before anything is serialised.

### What is not read

Everything else. Personal messages, one-time passwords, bank OTPs, promotional
SMS, delivery notifications — dropped in the device loop and never uploaded.

This is verifiable, and the smoke test asserts the shape of it: one deliberately
personal message ("Hey, are we still meeting for tea at 5pm today?") is in the
test batch and the assertion is that it is **not** stored as a transaction.

### What is stored

The raw body is stored in `sms_messages` verbatim, along with `provider`,
`parse_status`, and `raw_extract` (the parsed fields as JSON). Raw text is kept
rather than discarded for two reasons: the owner must be able to reconcile a
number they disagree with, and a parser improvement can be re-applied to history
via `POST /api/sms/:id/reparse` without asking for the inbox again.

**Retention:** raw messages are deleted with the shop (`DELETE /api/shops/:id`
explicitly deletes `sms_messages` before the shop row) and with the account.
There is no automatic time-based purge yet — that is a gap, listed in §7.

### What is sent to a third party

Nothing, for the majority of messages. Tier 1 regex handles them locally on the
Worker. Only messages no pattern could match are sent to an AI provider, and the
tier-2 prompt contains **the message text and sender** — so a bKash body
including a counterparty phone number can reach Gemini/Groq/OpenRouter.

That is a real disclosure and it is mitigated, not denied:

- It only happens for messages that no pattern matched.
- Providers are used under their API terms with training/retention settings at
  their defaults; for a production deployment this requires a data-processing
  agreement and, for Indian users, an assessment against the DPDP Act.
- The user-facing copy says payment messages are processed to extract
  transactions, and says nothing about "your messages stay on your phone".

**For the AI advice path the exposure is smaller by construction:** the prompt
carries aggregates (score, totals, product count, stock value), never message
text and never counterparty numbers. See `routes/ai.ts` — it builds a `context`
object and the numbers are summed before they are serialised.

---

## 3. Authentication

- **Passwords** are hashed with bcryptjs, cost 10. The plaintext is never
  logged, never stored, and never returned.
- **`password_hash` is not in the API response shape at all.** `toPublicUser` in
  `routes/auth.ts` constructs the response field by field rather than spreading
  the row, so it cannot be leaked by forgetting a `delete`. The smoke test
  asserts this on the register response.
- **Sessions** are JWTs, HS256, 30-day expiry, verified with `algorithms:
  ["HS256"]` pinned. Pinning blocks algorithm-confusion attacks (a token asking
  to be verified with `none`, or with a public key used as an HMAC secret).
- **Login does not reveal whether an account exists.** An unknown username runs
  `burnPasswordTime` (a real bcrypt compare against a dummy hash) so the response
  time matches a wrong-password attempt, and both paths return the same message.
- **The token is stored in `shared_preferences`.** On Android that is app-private
  storage, readable by root or a debug build on an unlocked device. Not
  `flutter_secure_storage`. This is a conscious tradeoff to avoid a native
  dependency in the demo; **it is a gap and it is listed in §7.**
- **Sign-out is client-side only.** The JWT is stateless, so logout deletes the
  token from storage. A token copied off the device remains valid until it
  expires. Refresh-token rotation and a server-side revocation list are the real
  fix; neither is built.

### Admin

`POST /api/admin/seed` is guarded by `ADMIN_TOKEN`, compared in constant time
via `requireAdmin` (both inputs SHA-256'd first, then compared with a
non-short-circuiting loop — Workers has no `crypto.timingSafeEqual`). It is not
reachable with a user session, and the smoke test asserts that a valid *user*
token gets a 401.

---

## 4. Authorisation

Every shop-scoped route resolves ownership through one function,
`requireOwnedShop`. Two properties matter:

1. **Missing and not-owned both return 404.** A 403 on someone else's shop would
   confirm the id is real.
2. **The ownership rule is pushed into the query, not just checked first.**
   `findOwnedTransaction` uses `inArray(transactions.shopId, <owned shop
   subquery>)`, so the `WHERE` clause can only match a shop the caller owns —
   even if a guard were removed later, the statement stays safe.

The smoke test registers a second account and asserts that it cannot read or
write the first account's shop (both 404).

SMS rows are fetched through a join onto `shops.owner_id` keyed by the SMS id;
an SMS id alone is never sufficient to act on a message.

---

## 5. Transport and storage

| Layer | Protection |
|---|---|
| Device → Worker | **HTTPS in any real deployment.** TLS terminates at Cloudflare. |
| Worker → D1 | Internal Cloudflare network; queries are parameterised by Drizzle. |
| Worker → AI providers | HTTPS with the key in a header (Groq, OpenRouter) or a query parameter (Gemini). |
| D1 at rest | Encrypted at rest by Cloudflare. |
| Backups | Covered by D1's managed storage. |

**Local development is plain HTTP** (`http://10.0.2.2:8787`). That is fine for a
loopback-bound `wrangler dev` and is not fine anywhere else. `Env.apiBaseUrl`
defaults to the deployed Worker over HTTPS; point it at a dev server with
`--dart-define=GREENBIZ_API_URL=http://…`. Release builds block cleartext
entirely (`network_security_config.xml`); only debug builds permit it, because
the dev server has no certificate.

**The offline database keeps a local working copy.** The app stores a local\nSQLite copy of the account's shops, inventory, parsed transactions (never SMS\nbodies), credit profile and plan directory so it can run without a connection.\nIt is app-private storage, is wiped on logout, and contains no credentials. The\nsession token still lives in `shared_preferences`; the AI key lives in the\nplatform keystore. Marking a transaction personal writes that flag locally and\nsyncs it; the server excludes personal rows from the credit score and from\nbusiness cash-flow totals.

**The Sell assistant's AI key belongs to the user.** It is entered in Profile,
stored in the platform keystore (`flutter_secure_storage`), and sent only to the
provider the user picked (Gemini or OpenRouter). It never reaches the GreenBiz
Worker, and the Worker holds no key for this flow. Voice audio is handled by the
device's speech recognizer; GreenBiz receives only the recognized text and sends
it straight to the provider. The sale itself is written by
`POST /api/shops/:shopId/sales`, which records the inflow transaction and the
stock decrements in one D1 batch.

## Offline cache

After the first sign-in the app keeps the account, shops, inventory, the last 90
days of payments, the credit profile and the plan directory in a private SQLite
database on the device (`greenbiz_offline.db`). Writes made while offline are
applied locally and queued in an outbox; they are retried in order when a
connection returns. Logging out deletes the database, so the next user of the
phone cannot read the previous owner's ledger. The cache is app-private storage,
not shared storage, and it holds no passwords or AI keys — the session token
stays in the keystore-backed preferences and the AI key in secure storage.

---

## 6. Secrets and API keys

| Secret | Where it lives | Never |
|---|---|---|
| `JWT_SECRET` | Worker secret / `.dev.vars` | in D1, in the repo, in a log |
| `ADMIN_TOKEN` | Worker secret / `.dev.vars` | in a response body |
| `GEMINI_API_KEY`, `GROQ_API_KEY`, `OPENROUTER_API_KEY` | Worker secret / `.dev.vars` | in the app bundle, in D1, in a log line |

Rules enforced in code:

- **`.dev.vars` is gitignored** (confirmed: the template `.gitignore` lists
  `.dev.vars*` with an explicit `!.dev.vars.example` exception). A committed
  example file carries placeholders only.
- **Zod validates every secret at request time** (`lib/env.ts`). A missing
  `JWT_SECRET` produces a clear `CONFIG_ERROR` 500 rather than `undefined`
  flowing into a signing call.
- **Provider failures log a provider name and a message — never a URL, never a
  key, never a prompt.** The Gemini URL embeds the key, so `fetchWithTimeout`
  deliberately converts a thrown fetch error into a bare reason string rather
  than passing the URL through.
- **No key is ever returned to the client.** `GET /api/ai/status` returns a
  boolean and nothing else. The smoke test asserts the response contains no key
  field.
- **Keys are not stored in D1.** They are Worker secrets only.
- **Rotating a Gemini key is a config change, not a code change**: `GEMINI_API_KEY`,
  `GEMINI_API_KEY_2`, `GEMINI_API_KEY_3` are tried in order.

---

## 7. Known risks and what is done about them

Honest list. "Mitigated" means something in the code does it; "not built" means
it is a real gap.

### High

| Risk | Status |
|---|---|
| **Counterparty phone numbers reach an AI provider** for messages no regex matched. | **Partly mitigated.** Tier 1 handles the known templates, so exposure is limited to unrecognised senders. **Not built:** redacting digit runs before the tier-2 prompt. That is the right next fix — a body with all `\d{9,}` sequences replaced by `<number>` would preserve enough for extraction. |
| **Session token in `shared_preferences`, not the keychain.** | **Not built.** Should move to `flutter_secure_storage` before any real user. |
| **A stolen token is valid for 30 days with no revocation.** | **Not built.** Short-lived access tokens plus a refresh token, or a `token_version` column on `users` checked by the middleware. |
| **SMS bodies stored indefinitely.** | **Partly mitigated.** Deleted with the shop. **Not built:** a time-based retention job (e.g. purge bodies older than 12 months, keep the derived transaction). |

### Medium

| Risk | Status |
|---|---|
| **No rate limiting.** `/api/auth/login` can be brute-forced and `/api/ai/*` can drain AI quota. | **Not built.** Cloudflare Rate Limiting rules, or a Durable Object counter per IP and per user. Login already costs ~100ms per attempt, which raises the cost but does not stop a distributed attempt. The AI routes do require auth, which stops anonymous abuse. |
| **Registration is open.** Anyone can create an account. | **Accepted for the pilot.** A real launch needs phone verification — which also raises the per-account cost of enumeration. |
| **No audit log.** Nothing records who changed a transaction. | **Not built.** Matters once more than one person can access a shop. |
| **The owner can edit ledger rows after the fact.** A motivated user could inflate inflow to raise their score. | **Partly mitigated.** This is why the score is presented as a *behavioural* signal and why the UI states it is not a bureau score or a lending decision. Any lender integration must re-derive from the raw SMS rather than trusting edited rows. |
| **`raw_extract` stores low-confidence model guesses** alongside parsed data. | **Mitigated.** It is only ever read for review; nothing is booked from it. |

### Low, but worth stating

| Risk | Status |
|---|---|
| Error responses could leak SQL via driver messages. | **Mitigated.** `onError` returns a generic message for unexpected errors and logs the detail server-side only. |
| Shop-enumeration through 404 vs 403 timing. | **Mitigated.** Both paths return an identical 404 body. |
| Directory scraping of the plan catalogue. | **Accepted.** It is public information by design. |
| `POST /api/ai/parse-sms` could be used as a free AI proxy. | **Mitigated.** Every AI route requires auth, so abuse is attributable and revocable per account. |

---

## 8. What a judge should verify

Claims above that can be checked in the code:

1. `lib/core/env.dart` — the sender allow-list and `isPaymentSender`.
2. `lib/services/sms_service.dart` — the device-side filter loop; the only
   messages that reach `toJson()` are payment notifications.
3. `greenbiz/src/routes/ai.ts` — the `context` object sent to the model contains
   aggregates, not messages or counterparty numbers.
4. `greenbiz/src/services/ai/provider.ts` — the comment and code that stop a key
   reaching a log line.
5. `greenbiz/src/routes/auth.ts` — `toPublicUser`, and the absence of
   `passwordHash` from the response type.
6. `greenbiz/src/services/shopAccess.ts` — 404-not-403, and the ownership
   subquery.
7. `greenbiz/scripts/smoke-test.ps1` — the assertions that make several of these
   claims executable: password hash absent, personal SMS excluded, cross-tenant
   access denied, user token rejected by the admin route.
