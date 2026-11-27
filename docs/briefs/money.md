# Brief: Money (receipts, refunds, daily closing, packages, payment links) · CMD-114

Parts: 0 Data CMD-115 · 1 Today and Collect CMD-116 · 2 Outstanding CMD-117 · 3 Daily closing CMD-118 · 4 Receipts and bills CMD-119
· 5 Payment links and Fonepay QR CMD-120 · 6 Packages CMD-121 · 7 Owner phone CMD-122. Epic CMD-4. Open with Sadin: CMD-123 (IRD), CMD-124 (mid-year mode).

**Status:** boards approved by Sadin 2026-11-23 (canvas "ClinicMD Mockups", page **14 Money**, 43 boards: 39 desktop + 4 owner
phone). **Lead:** lead session. **Follows:** `docs/PRODUCT-BRIEF.md` §2 Money decisions of 2026-11-23 (Bills, Memberships/vouchers/
referrals, Payment links, Refunds and closed days), `docs/SITEMAP.md` §3.5, `docs/DESIGN-DIRECTION.md` (§6 phone, §11 mockups are final).
**Sadin's rule (2026-11-23): groundwork first.** Part 0 (data and functions) may start now. Screen parts wait until Part 0
works and the phase allows (Today, Collect, Outstanding, Packages and Daily closing are P3; Receipts, Payment links and Fonepay QR are P5).

**Nothing that exists today is lost:** the payment modal (split tenders, wallet, packages, "leave as due" under a named person),
the outstanding report with settled history and "needs closing", daily closing (gross, discounts, net, by method; a closed day locks
its bookings), package types and issued packages with redemptions, and payment methods in master data. Memberships, vouchers and
referrals stay as they are behind their flags (CMD-14); Money's new screens show packages only.

## 1. Parts (one branch and PR each; the PM creates the tickets under one Money epic)

| Part | What | Phase | Boards |
|---|---|---|---|
| 0 Data | Receipt and bill numbering, the BS calendar and fiscal year, refunds and refund requests, the two-step daily closing with blind cash count and owner reopen, locks that cover payments, the actions. No UI. | groundwork, now | none |
| 1 Today and Collect | Today (all roles and states), Collect payment (methods, split, paid; QR states once Part 4 exists) | 3 | MoneyToday*, MoneyCollect* |
| 2 Outstanding | Dues by person, detail, needs closing, settled, front desk view, empty, agents paused | 3 (Collections agent parts in 5) | MoneyDues* |
| 3 Daily closing | Front desk count, blocked, short, closed, reopen, owner | 3 | MoneyClose* |
| 4 Receipts and bills | List, view, PAN bill, refund, front desk refund request, cancel PAN bill | 5 | MoneyReceipt* |
| 5 Payment links and Fonepay QR | Links list, send, match, not connected; QR in Collect | 5 (needs a Fonepay merchant account) | MoneyLinks*, MoneyCollectQr/Expired |
| 6 Packages | List, types, sell, detail | 3 | MoneyPackage* |
| 7 Owner phone | 4 phone boards | 3 | Phone money boards |

## 2. Part 0: what to build

**Where:** worktree `~/Projects/clinic-md-money-data`, branch `feature/CMD-<id>-money-data` from `origin/feature/CMD-97-playbooks-new-orgs`
(#22), then merge `origin/feature/CMD-79-practitioner-access` (011): #16-#22 don't contain it. **Migration 021** (019 = CMD-100,
020 = CMD-54; check every open branch and Plane, then claim it in the ticket). Don't depend on 019 or 020. Local DB only.
CMD-83 (014) already guards the money SECURITY DEFINER functions. Follow its patterns and don't loosen them.

### 2.1 BS calendar and fiscal year
- Nothing in the repo converts AD to BS today (no library, no table). Add a table `bs_calendar` (ad_date PK, bs_year, bs_month,
  bs_day) covering at least BS 2075 to 2100. Generate it from a maintained open-source converter at build time, with the data
  checked into the migration, not computed at runtime. Name the source and its version in the design note.
- `bs_date(ad date)` returns the BS date. `fiscal_year(ad date)` returns `'2083/84'`: a Nepali fiscal year starts on 1 Shrawan (BS month 4).
- Tests: at least 10 known AD↔BS pairs from an official calendar (Nepal government calendar), including both sides of
  1 Shrawan and of a BS year end. List the source of each pair.

### 2.2 Receipts and bills
- One table `money_documents`: org_id, branch_id, kind (`receipt` | `refund_note` | `pan_bill` | `credit_note`), series, fiscal_year,
  seq, number (text as printed), customer_id, booking ids, lines (jsonb: label, amount, ref), total, method summary, issued_by,
  issued_by_name, issued_at, bs_date, related_document_id (refund note or credit note points at its receipt or bill),
  status (`issued` | `cancelled`), cancel_reason, cancelled_by, cancelled_at, print_count, sent (jsonb: channel, to, at).
- **Numbering:** gapless per org, series and fiscal year, with a counter row lock (same pattern as CMD-100's `patient_counters`).
  - Receipt mode: receipts and refund notes share one series, printed `2083/84-1189`.
  - PAN bill mode: bills are numbered `1189` per fiscal year, and credit notes `CN-14` per fiscal year.
  - A number is never reused and a document is never deleted.
- **Immutable:** a trigger refuses UPDATE of any column except `print_count`, `sent`, and the cancel columns, and DELETE is refused.
  - A receipt is corrected only by a refund note.
  - A PAN bill is corrected only by cancelling it and issuing a credit note in the same transaction.
- **Original and copy:** `print_count` 0 → the first print says "Original", later prints say "Copy". The print counter is incremented by one function.
- **Settings:** `org_billing_settings` (org_id PK, pan, pan_bill_mode boolean, mode_changed_at, mode_changed_by). Only the owner (admin)
  changes the mode, and the change is audited. Changing mode mid-fiscal-year is refused in Part 0 (`MODE_CHANGE_MID_YEAR`) until Sadin rules (§5).
- **Issue on payment:** a function `money_collect(...)` records the tenders (existing `payments` rows, plus `payments.document_id`)
  and issues the receipt or bill in **one transaction**. Today's collect path is not rewired in Part 0: Part 1 switches it. Part 0
  proves the function with tests.
- **Sales register:** a view (security_invoker) listing PAN bills and credit notes per fiscal year, cancelled ones included,
  with the columns an accountant needs (number, BS date, buyer, buyer PAN, amount, status).

### 2.3 Refunds
- Only manager and admin refund. A reason is required (the patient sees it). Partial or full, never more than paid less earlier refunds.
- Writes `payment_refunds` (existing table, gains `document_id` and `paid_back_by` method) and a `refund_note` document in one transaction.
- A cash refund counts against that day's drawer at closing.
- Front desk can't refund. It creates a `money_requests` row (kind `refund`, document, note, requested_by, assigned_to = the manager
  on duty or any manager of the branch, status `open` | `done` | `declined`). Home shows these later (Part 4/Home), and Part 0 only stores them.

### 2.4 Daily closing (extends today's `daily_reports` + `bookings.is_locked`)
- Two steps, as drawn:
  1. Front desk submits a **blind count** per method (cash counted before expected amounts are shown; the function doesn't
     return expected values to `staff`).
  2. A manager checks and closes.
  - A difference needs a reason. The owner sees closings with a difference.
- **Blockers** (closing refused with the list): a visit still in chair, a completed visit neither paid nor left as due, an open QR or
  payment link (Part 5 adds these; the check is in place and empty until then).
  - Fonepay settlement is shown as information and doesn't block until Part 5.
- **Lock:** closing locks that day's bookings (as today) **and** refuses new or changed payments, refunds, discounts and documents dated that day for that branch.
  Today only bookings are locked. Add the same check on `payments`, `payment_refunds` and `money_documents`.
- **Reopen:** only the owner (admin), with a reason, audited. It unlocks the day, keeps the old closing as history (`daily_reports`
  gains `reopened_at`, `reopened_by`, `reopen_reason`, superseded_by), and the day must be closed again.
- `closeDay` in `api.js:3355` today writes `daily_reports` and locks bookings from the client. Part 0 adds the functions, and Part 3 switches the client.

### 2.5 Actions (via the action layer, 012; each writes `action_log`)
`money.collect` (front desk, manager, owner), `money.refund` (manager, owner), `money.request_refund` (front desk), `bill.cancel`
(manager, owner), `document.print`, `document.send` (front desk, manager, owner), `day.submit_count` (front desk, manager), `day.close`
(manager, owner), `day.reopen` (owner), `billing.set_mode` (owner). Practitioners have no money access (011). `admin_viewer` reads only
and writes nothing (CMD-83).

### 2.6 Tests
- test:rls:
  - another org sees no documents, counters, requests or closings;
  - practitioner and admin_viewer can't call any write;
  - staff can't refund, close or reopen, and never receives expected cash before submitting the count;
  - a locked day refuses each kind of write;
  - documents can't be updated or deleted.
- Numbering: gapless under 20 concurrent `money_collect` calls; a rolled-back collect uses no number; the fiscal year turns over at 1 Shrawan.
- Vitest: action mapping, and number formatting per mode.
- `npm test`, `npm run build`, `npm run test:rls` pass. The migration and its rollback round-trip on local.

### 2.7 Acceptance checks (the lead runs these)
1. On local:
   - a split-tender collect gives one receipt `2083/84-NNNN` with the right lines and total;
   - a partial refund gives a linked refund note;
   - in PAN bill mode a bill `NNNN` and a cancel give a credit note `CN-N`, and the bill shows Cancelled in the sales register.
2. A day with a visit not paid or due can't be closed. After closing, a payment, refund or document for that day is refused.
   Owner reopen works and is audited, and close again works.
3. Front desk's blind count never returns expected amounts. A difference without a reason is refused.
4. The AD↔BS test pairs pass, including 1 Shrawan.
5. Existing payments, refunds, closings and packages behave exactly as today on the current screens (nothing rewired yet).
6. Rollback restores the previous schema with existing rows unchanged.

## 3. Design checkpoint
Before SQL, send the lead a design note (`docs/briefs/money-data-design.md` on the branch). It covers:
- the tables;
- the counter and numbering;
- the BS source;
- how locks are enforced per table;
- each function's role check (compared with 014);
- how `money_collect` relates to the current collect path (list the files and RPCs it calls today);
- the rollback.
The lead approves it above 9/10 before you write code.

## 4. Production notes (hand-off, not for the builder)
- 021 is applied by a human after 011-018 (and 019 and 020 if they are merged first).
- Turning on PAN bill mode for a clinic is an owner setting, and nobody turns it on before §5 is settled.

## 5. Open with Sadin (not built until answered)
1. **IRD compliance.** Billing software that issues tax invoices in Nepal may need to be registered or certified with the IRD
   (electronic billing rules, and the CBMS link for larger businesses). Part 0 builds the data rules (sequential, immutable,
   cancel by credit note, original/copy, sales register) but **must not be called "IRD-compliant" in the product** until an accountant
   or the IRD confirms what ClinicMD needs. Who checks this, and by when?
2. Can a clinic switch to PAN bill mode in the middle of a fiscal year? Part 0 refuses it until you rule.

## 6. Not verified (lead)
- The IRD rules above are from general knowledge, not checked against a current IRD directive.
- The BS calendar source is not chosen yet. Every pair must be checked against an official calendar.
- Whether prod has the `daily_reports` and lock trigger exactly as `schema.sql` shows (CMD-11).
- The receipt layout on the boards (no VAT line, "Health services are exempt from VAT") is from Sadin's decision. Not legally checked.
