# Demo Script — 5 minutes

The goal is not to show every screen. It is to make one sentence land:
**a shop owner's payment SMS becomes a credit profile, without them typing
anything.**

Judges are fintech people. They will care about: where the data comes from, what
the score actually measures, what happens when the model is unsure, and what you
are *not* doing.

---

## Before the judges arrive

Do these in advance. Do not do them on stage.

```powershell
# 1. Worker running
cd C:\myprojects\greenbiz\greenbiz
npm run dev                          # http://127.0.0.1:8787

# 2. In a second terminal: schema + catalogue (first run only)
npm run db:migrate
npm run seed

# 3. Confirm the API is healthy and the AI key is loaded
curl.exe http://127.0.0.1:8787/api/health

# 4. App installed and running on the emulator
cd C:\myprojects\greenbiz
flutter run -d android
```

**Checklist**

- [ ] `.dev.vars` has a real `GEMINI_API_KEY` → `/api/health` shows `"aiConfigured": true`
- [ ] `curl /api/plans` returns 21 plans (not `[]` — that means seeding did not run)
- [ ] Emulator has SMS history. **If it does not, seed the emulator's inbox** or use
      the manual fallback in Step 3.
- [ ] Phone/emulator brightness up, notifications silenced

**Two things that will otherwise bite you**

1. A physical device cannot reach `127.0.0.1`. Pass your LAN address:
   `flutter run -d android --dart-define=GREENBIZ_API_URL=http://192.168.x.x:8787/api`
2. `wrangler dev` uses a **local** SQLite file. If you previously seeded remotely,
   the local database is still empty. `npm run seed` after `npm run db:migrate`.

---

## The script

### 0:00 – 0:30 — The problem

> "A shop in Dhaka takes Tk 1,500 by bKash. That payment exists — as an SMS.
> It's not in any system a lender can read. So the shop has no verifiable
> turnover, so it gets no working capital loan.
>
> GreenBiz reads those messages and turns them into a credit profile. Three
> tabs: inventory, finance, profile."

Do not open the app yet. Set the frame first.

---

### 0:30 – 1:30 — Register, then inventory

Register a fresh account. Point out that **registration creates the shop for
you** — no setup wizard.

Add one product: name `Aromatic rice 5kg`, unit `bag`, price `950`, stock `24`.

> "Inventory is the boring half, and it matters: stock value is a real asset on
> the balance sheet, and it's what the AI advice reasons about later."

Tap back to the list. Note the stock-value total and the low-stock chips.

---

### 1:30 – 2:30 — Sync the messages (the core)

Go to **Profile**. Show the permission card. Read the copy aloud — it is
deliberate:

> "We read payment confirmations from bKash, Nagad, and Rocket so you don't have
> to enter them manually. We never read personal messages."

Tap **Grant permission** → **Sync SMS now**.

The result summary appears. **This is the number to pause on:**

> "Read 412 messages on this phone. 9 were payment confirmations. Those 9 were
> uploaded. The other 403 — family, OTPs, promotions — were filtered on the
> phone. They never left the device."

Then go to **Finance**. Cash flow has real totals, and the credit score has a
number with four factors under it.

> "That score came from the ledger, and the ledger came from the SMS. Nobody
> typed any of it."

---

### 2:30 – 3:15 — Prove the parsing is real

Switch to the terminal. This is the part that separates a working parser from a
slide.

```powershell
curl.exe -X POST http://127.0.0.1:8787/api/ai/parse-sms ^
  -H "Content-Type: application/json" ^
  -H "Authorization: Bearer <paste token>" ^
  -d "{\"sender\":\"16247\",\"body\":\"You have received Tk 1,500.00 from 01782665484. Fee Tk 0.00. Balance Tk 1,699.05. TrxID DJG73D7KLD at 16/10/2026 15:46\"}"
```

Read the response out:

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

Three points, in this order:

1. **`amountMinor: 150000` means Tk 1,500.00.** "Money is an integer in the
   smallest unit everywhere — never a float. `1699.05 × 100` is
   `169905.00000000003` in binary floating point. That doesn't stay hidden
   across a ledger."
2. **`tier: 1`, `parseSource: "regex"`.** "This was a regex, not an LLM. Free,
   deterministic, ~1ms. The model is only a fallback for templates we haven't
   seen."
3. **`reference: "DJG73D7KLD"`.** "That's the TrxID, captured verbatim — the
   thing you'd quote to bKash in a dispute."

---

### 3:15 – 4:00 — What the score actually measures

Back to the Finance tab, on the **Credit profile** card.

> "Four factors, weighted: consistency 30%, volume 25%, stability 25%, activity
> 20%. Every one of them is a sentence a shop owner can act on, and each bar
> shows the points it contributes."

Point at the **risk flags**.

> "These are the honest part. If revenue fell 30% month on month, it says so. If
> all the revenue comes from one payer, it says that's a concentration risk. A
> score you can't interrogate is a score you can't improve."

Tap **Recalculate** to show it is live and deterministic.

Also state the limitation unprompted:

> "This is a behavioural score from the shop's own records. It is not a credit
> bureau score and it is not a lending decision — and the card says exactly
> that."

---

### 4:00 – 4:30 — Plans, matched to recorded revenue

Scroll to **Loan plans**.

> "Thirty-nine real products from eight Bangladeshi banks: BRAC, Sonali, EBL,
> DBBL, Jamuna, Dhaka, Prime and City Bank. Amount bands, rates, tenor,
> eligibility and source links are in the catalogue."

Point at the **How much you can borrow** panel.

> "The estimate uses half of average monthly business revenue as the instalment
> ceiling. Revenue covering the instalment twice or more is a high-priority
> plan; that is the owner's rule. The same numbers produce the suggested loan
> amount, so the headline and the plan labels cannot contradict each other."

Point at a plan's reasons.

> "Every ranking is explained: the EMI, the coverage multiple, the amount the
> plan supports, and what the lender will ask for — collateral, guarantees,
> business age. Those are requirements, not hidden filters. The app cannot
> verify them, and every EMI is an estimate, not an approval."

---

### 4:30 – 5:00 — AI, then the privacy close

Tap **Ask AI for advice**, choose **Loan**, submit.

> "The Worker builds a prompt from your aggregates — score, monthly average,
> volatility, stock value — and falls back Gemini → Groq → OpenRouter. The keys
> never leave the Worker; the phone only ever receives text."

Then the close. Be specific:

> "Three things I want you to take away.
>
> One: the sender filter runs on the phone. Not here. Personal messages never
> upload — that's a code path you can read.
>
> Two: a lender would only ever see aggregates. Never messages, never a
> customer's phone number — although today, an unrecognised message that needs
> the LLM does send its text to the provider, and redacting digit runs before
> that call is the next fix.
>
> Three: the two-tier parser means the common cases cost nothing and work
> offline from the model. The AI is a fallback, not the product."

---

## Fallbacks

### No AI key configured

Do not skip the AI section — demo the degradation, it is a feature.

`/api/health` returns `"aiConfigured": false` and the Finance tab replaces the
button with "AI advice is not configured on the server yet. Add
`GEMINI_API_KEY` as a Worker secret to enable it."

> "It fails closed and tells you what to configure, instead of erroring."

SMS parsing still works completely — tier 1 is regex. Messages the regex cannot
match are stored as `pending` with the reason, and `POST /api/sms/:id/reparse`
re-processes them once a key exists. Show that if you have a pending row.

### Emulator inbox is empty

SMS sync will report "No new payment messages found." Do not fake it — instead:

```powershell
# Send the parser the same templates directly, and show the ingest is idempotent
cd C:\myprojects\greenbiz\greenbiz
powershell -File scripts/smoke-test.ps1
```

The smoke test asserts all of it: 7 payment templates parsed at tier 1, the
personal message excluded, re-upload adding zero rows, the score recomputed,
cross-tenant access denied. It is a faster, more complete proof than tapping
through the UI.

### No device at all

Run the app's screenshots if you have them, then fall back to the smoke test and
the `curl` calls for Steps 2–4. The API is the whole product; the app is a client
for it.

---

## Questions to expect

**"How is this different from a bank statement?"**
Most of these shops do not have a bank account with meaningful turnover. Mobile
money is their account. This is the only ledger that exists.

**"Isn't the score gameable?"**
Yes, partly — the owner can edit a row. That is why it is labelled behavioural
and why any lender integration must re-derive from the raw SMS rather than trust
edited transactions. The raw messages are retained, so re-derivation is possible.

**"What about the AI sending messages to Google?"**
It happens, only for templates no regex matched, and it is documented as a gap in
`SECURITY.md`. The fix is to redact long digit runs before the tier-2 prompt.

**"Can you use this in India?"**
The parser has UPI patterns and INR currency inference, and the directory has
Indian lenders. The privacy posture would need a DPDP Act review before launch —
also in `SECURITY.md`.
