# SMS payment parser

GreenBiz parses mobile-money confirmations in three places:

| Where | File | Purpose |
| --- | --- | --- |
| Worker | `src/services/smsParser/structural.ts` | Authoritative booking decision |
| Flutter | `lib/core/sms_structural.dart` | Inbox filter + live prompt |
| Android | `android/app/src/main/kotlin/com/asrumon/greenbiz/PaymentSms.kt` | Background notification |

All three implement the same structural algorithm. **When one changes, change
all three** and run both test suites.

## Why not one regex per template?

Providers change wording without notice. A template list silently stops
matching, which looks like missing revenue rather than an error. The structural
parser reads the parts every confirmation shares instead:

```
[provider] [direction phrase] [currency amount] [counterparty]
[TrxID] [fee] [balance]
```

The existing provider templates are still tried first for speed and backward
compatibility. The structural parser runs next, and the LLM runs only after
both fail.

## Rules

1. **Candidate filter** — a known sender is accepted. An unknown sender needs a
   provider brand plus a TrxID, or a received-money phrase plus an amount.
   OTPs and promotional messages are rejected.
2. **Amount** — every money-looking number is collected. Numbers preceded by
   `balance`, `available`, `current`, `total`, `wallet`, `fee`, `charge`,
   `limit`, or `due` are discarded. The remaining candidates are scored by a
   nearby transaction verb and by `to` / `from`, then the highest score (earliest
   on a tie) wins. This is what prevents a balance from being booked as a sale.
3. **Direction** — weighted phrases:
   - Money in: received, received payment, merchant pay received, collection of,
     cash in, add money, added to your account, credited, deposited.
   - Money out: sent, sent money, merchant pay of, cash out, recharge,
     bill pay/bill payment, transfer/transferred, paid, payment of, debited,
     withdrawn.
   - The first `from` vs `to` after the amount adds a final nudge. A tie is
     treated as incoming, which is the safe default for a merchant.
4. **Reference** — TrxID / TxnID / Transaction ID first, then Ref / Reference.
5. **Digits** — Bengali and Devanagari numerals are normalised to ASCII before
   any regex runs.

## Extending it

- **New shortcode** — add it to `SENDER_MAP` (Worker),
  `Env.paymentSenderIds` (Flutter), and `paymentSenderIds` (Kotlin).
- **New brand/rebrand** — add the brand word to `providerMention` (Worker) and
  `detectPaymentProvider` (Flutter/Kotlin). If it is a new provider, add it to
  `SmsProvider`, `PROVIDER_CURRENCY`, the payment-method enum, and the UI labels.
- **New currency** — add the word to the amount regexes and `inferCurrency`.
- **Ordinary wording change** — no code change. Add the new sample to
  `test/smsParser.spec.ts` and `test/live_sms_test.dart` as a regression.

## Verification

```powershell
cd greenbiz
npx tsc --noEmit
npx vitest run

cd ..
& 'C:\Flutter\flutter\bin\flutter.bat' analyze
& 'C:\Flutter\flutter\bin\flutter.bat' test
& 'C:\Flutter\flutter\bin\flutter.bat' build apk --debug
```

The parser tests include every bKash, Nagad, Rocket, and Upay consumer and
merchant layout that was supplied as a design sample, plus future-wording
variants.
