# GreenBiz — SME Finance Copilot

An Android app for small business owners in Bangladesh and India. It manages shop
inventory, turns mobile-money SMS (bKash, Nagad, Rocket, UPI) into structured
transactions, and computes a behavioural credit profile from those transactions.

```
Inventory  →  payment SMS  →  structured transaction  →  credit score  →  matched loan plans
```

Sales can be recorded from the Inventory tab with **Sell**: search products and
set quantities, or dictate what the customer bought ("3 kg rice and two
notebooks"). The voice path uses a two-pass AI lookup — sentence to search terms,
then inventory results back to the model — with the shop owner's own API key
entered in Profile. That key never reaches the Worker.

Confirming is a **two-sided swipe**: swipe right for cash, swipe left for mobile
money. The mobile-money sheet suggests the payment messages from the **last ten
minutes** — a bKash/Nagad/Rocket/UPI confirmation lands a minute or two after
the customer pays, so a hit from yesterday is almost always a different sale —
and highlights one that matches the sale total. Mobile money rarely lands on the
exact total: the customer adds the cash-out charge, which runs about **10-20 taka
per thousand**, so any message within **2% (at least ৳1) of the bill** is treated
as the same payment and labelled with its difference, e.g. *+৳15 cash-out
charge*. Those are listed first. **Refresh** re-scans the inbox for messages that
just arrived, and **Look further back** — or picking a method by hand — opens the
full list of inbound message payments from the last 30 days so an earlier
payment can still be attached; choosing a method also offers *Use bKash without
a message*. Attaching a message links the sale to that existing payment row, so
the same money is not counted twice.

Adding a product can start from a **photo**. The camera icon (on the Add product
button and in the Inventory app bar) opens the camera, compresses the capture to
full HD (longest side 1920 px, JPEG q85) on a background isolate, and sends it
to the AI provider with a prompt to return strict JSON — `productName`, `unit`,
`priceMajor`, `confidence`, `notes`. The sheet pre-fills name, unit and price and
leaves the stock count for the owner to confirm. The photo is never uploaded to
the Worker and is not stored on the device. Gemini 2.5 Flash reads the label
directly; with OpenRouter pick a vision-capable model (`openrouter/auto` usually
resolves to one).

## Web dashboard

The same account works in a browser. The Worker serves a single-page dashboard
from `greenbiz/public/index.html` at the root of the deployment
(<https://greenbiz.asrumon.workers.dev>), so a shop can be run from a laptop or a
tablet with no install.

It is deliberately laid out like the app, with the same three tabs, the same
screen names and the same field labels — learn it once and both clients work the
same way:

| Tab | What it is | Where the app puts it |
|---|---|---|
| **Inventory** | "Stock at a glance" card (total stock value, *N products tracked*, *N out of stock* / *N running low*), then products with *Price / unit* and *in stock*. Actions: **Add product**, **Sell** | Tab 1, same FABs |
| **Finance** | Cards in the app's order: **Cash flow** (*Money in* / *Money out* / *Net this month* / *N transactions recorded*) → **Payments** (*SMS and manual entries*, *See all payments*) → **Credit profile** (*out of 100*, band chip, *What shapes your score*, factor bars as *x/100 · y% weight*, *What to work on*) → **Payment messages** | Tab 2, same cards |
| **Profile** | Account card, **Your shops**, **Data & privacy**, **Session** (*Signed in as*, *Log out*) | Tab 3, same cards |

Two screens are pushed from their parent tab, exactly as in the app:

- **New sale** (from Inventory) — **Add products** / *Search your inventory* /
  *Search by name* → **Receipt** (*N items · stock will be reduced when you
  confirm*), *Total*, *Customer name (optional)* (*Walk-in customer*), then
  **Cash** or **Mobile money**. Mobile money shows the ten-minute payment
  messages, *Look further back*, *or choose the method* and *TrxID (optional)*.
  The receipt reads *Sale recorded*, *Paid by …*, *TrxID …*, *Your credit score
  is now N/100.*
- **Payments** (from Finance) — *All / SMS / Manual / Personal*, rows with the
  *SMS* or *Manual* and *Business* or *Personal* chips, and the app's messages
  when a row is flipped (*Marked as business. It counts toward your sales and
  score.*).

Product fields are the app's: **Product name**, **Unit**, **Selling price**,
**Stock on hand**, with **Add to inventory** / **Save changes**. Sign-in fields
are **Username or email**, **Password**, **Your name**, **Email (optional)**,
**Shop name (optional)**.

Everything goes through the same API the Android app uses, so the two clients
never disagree about stock, the ledger or the score. SMS ingestion stays on the
phone — the browser can see, list and link messages that were already imported,
but it cannot read an inbox. Layout is a sidebar on wide screens and a bottom
tab bar under 860px.

## Offline-first

After the first sign-in the app works from a local SQLite database, so the shop
keeps running without a connection:

- **Reads** — inventory, payments, credit profile and the plan directory come
  from the local cache. The cached session restores the account offline.
- **Writes** — products, sales, manual payments and personal/business changes are
  written locally and queued in an outbox.
- **Sync** — the queue is pushed and fresh server state is pulled on launch, when
  connectivity returns, when the app is resumed, and on pull-to-refresh. Queued
  writes carry client-generated ids, so a retry after a dropped reply cannot
  double-book a sale.
- **Still online-only** — first login/registration, SMS inbox sync, score
  recomputation and AI advice.

A strip above the tabs shows *offline*, *N waiting to sync*, *syncing*, or a
permanent sync failure. Nothing in the app blocks on it.

**Payments** (Finance → Payments) lists both SMS-imported and manual entries.
Swipe right to mark a row business, swipe left to mark it personal (long-press
also works). Personal rows stay visible but are excluded from the cash-flow
figures and the credit score.

## Repository layout

| Path | What it is |
|---|---|
| `lib/` | The Flutter Android app |
| `test/` | Flutter unit and widget tests |
| `android/` | Android host project (manifest, Gradle) |
| `greenbiz/` | The Cloudflare Worker: Hono + Drizzle + D1, and the whole API |
| `ios/`, `macos/`, `linux/`, `windows/`, `web/` | Untouched scaffold. Android only is targeted. |

Documentation:

- `greenbiz/docs/ARCHITECTURE.md` — the pipeline, why D1, why money is an integer, and how loan matching ranks
- `greenbiz/docs/SECURITY.md` — permission tiers, data classification, known gaps
- `greenbiz/docs/DEMO_SCRIPT.md` — the 5-minute walkthrough
- `greenbiz/README.md` — backend setup, end to end

## Quick start

Two processes: the Worker and the app.

```powershell
# Terminal 1 — the API on http://127.0.0.1:8787
cd greenbiz
npm install
npm run db:migrate      # create the tables in the local D1
npm run seed            # load 14 institutions and 21 plans
npm run dev

# Terminal 2 — the app on an emulator or device
cd ..
flutter pub get
flutter run -d android --dart-define=GREENBIZ_API_URL=http://10.0.2.2:8787/api
```

Without `--dart-define` the app talks to the deployed Worker at
`https://greenbiz.asrumon.workers.dev/api`, so a bare `flutter run` works on any
device with internet access. **On a physical device against a local Worker**, use
that computer's LAN IP — `10.0.2.2` only exists inside the Android emulator:

```powershell
flutter run -d android --dart-define=GREENBIZ_API_URL=http://192.168.1.5:8787/api
```

Debug builds allow cleartext HTTP (see `src/debug/res/xml`), so a LAN address
works. Release builds only permit HTTPS.

## Requirements

- Flutter 3.47+ (Dart 3.13+) — the project's `environment.sdk` is `^3.13.3`
- Node 20+
- Android SDK with **compileSdk 37** (`permission_handler_android` 14.x requires it)
- A Cloudflare account, only for `wrangler deploy`

## Secrets never enter the repository

`.gitignore` blocks credential files outright, so a stray `git add -A` cannot
ship one:

| Blocked | Why |
|---|---|
| `.dev.vars`, `.dev.vars.*`, `.env`, `.env.*` | JWT signing key, admin token, AI provider keys. Only the placeholder template `greenbiz/.dev.vars.example` is committed. |
| `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.jks`, `*.keystore`, `key.properties`, `keystore.properties`, `signing.properties` | Certificates and Android signing material |
| `google-services.json`, `GoogleService-Info.plist` | Embed API keys and project ids |
| `.npmrc`, `.netrc`, `secrets.json`, `.secrets/`, `*.kdbx` | CLI and package-manager credentials |
| `.wrangler/`, `greenbiz/dist/`, `.history/`, `.lh/` | Local D1 state, build output, and editor snapshot trees that can copy everything above |

- **Local development:** `copy greenbiz/.dev.vars.example greenbiz/.dev.vars`,
  then fill it in. `greenbiz/.dev.vars` never leaves the machine.
- **Deployed Worker:** `npx wrangler secret put JWT_SECRET` (and `ADMIN_TOKEN`,
  the AI keys). Secrets are set once and read only inside the Worker.
- **Demo data:** `scripts/seed-demo-account.ps1` takes the password from
  `-Password` or `$env:GREENBIZ_DEMO_PASSWORD`. It has no default, so the repo
  never carries a working login.
- **Before committing:** `git status --short --ignored` should show any secret
  file under `!!`, never under `??` or `A`.


## What is deliberately not built

- **Insurance matching.** The catalogue currently holds the 39 SME loan and
  working-capital products supplied on 2026-10-18. The insurance intent still
  reaches the AI advisor, but no insurer rows are seeded.
- **Website generation.** Out of scope.
- **Barcode/QR lookup against a product database.** The camera path reads the
  printed label; it does not resolve barcodes or look products up online.
- **iOS.** Android only. The other platform folders are untouched scaffold.

## Verification

```powershell
cd greenbiz
npx tsc --noEmit              # Worker typecheck (strict)
npx vitest run                # 57 Worker tests (parser, scoring, HTTP contract)

cd ..
flutter analyze               # Flutter analyzer
flutter test                  # 80 Flutter tests (offline model, AI parsers, camera, payments)

# End to end, against a running `npm run dev`:
powershell -File greenbiz\scripts\smoke-test.ps1   # 67 assertions
```

