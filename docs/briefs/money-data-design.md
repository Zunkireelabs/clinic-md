# Design note: Money Part 0 (data) · CMD-115 · migration 021 · revision 2

Status: DRAFT round 2 for lead review. **No SQL written.** Builder session, 2026-11-24. Brief: `docs/briefs/money.md` §2, §3.
Base: `feature/CMD-97-playbooks-new-orgs` + merge of CMD-79 (011). Local DB only. Does not depend on 019 or 020.
Migration 021 is being claimed on CMD-115 by the PM (not confirmed to me).

## Change list since round 1 (lead QC 8.4/10)
R1 lock by money-event date, old dues paid today (§5, §6) · R2 cancel behaviour, Part 1 follow-up (§7) · R3 BS pairs listed, Sadin checks (§4) ·
C1 number key fixed (§1.4) · C2 `created_at`/`issued_at` forced to `now()`, locks check OLD and NEW day (§5) · C3 wallet tenders refused (§6) ·
C4 `p_lines` allocation, OVERPAY, MIXED_BRANCH, MIXED_CUSTOMER (§6) · C5 only `act_*` granted (§3) · C6 counter first-row and test harness (§2) ·
C7 staff return shape, no leaks in errors (§8) · C8 admin may submit a count (§3) · C9 `money_collect` checks the day before taking a number (§6) ·
C10 rollback order and proof (§9).

## 0. Facts found on this branch
- `payments(id, booking_id, amount, payment_mode, recorded_by, notes, created_at)`: no org, branch or date column. `created_at` has `DEFAULT now()` but the client can set it (C2). Trigger `trg_payment_update_booking_status` (AFTER INSERT/UPDATE OF amount, booking_id/DELETE, SECURITY DEFINER, 007) refuses when the booking `is_locked` (DAY_LOCKED), then calls `sync_booking_payment_status` (definer, locks the booking row, updates `bookings.payment_status` only).
- `bookings`: `enforce_booking_immutability` (BEFORE UPDATE, **not** definer) refuses *any* change when `OLD.is_locked`. Discounts are columns on `bookings` (so covered by that).
- `payment_refunds(id, booking_id, org_id, amount, refunded_by, reason, created_at)`: no lock check. `handle_booking_cancellation_refund` (BEFORE UPDATE on bookings, invoker) inserts a full refund when a paid/partial booking is cancelled and sets `payment_status='refunded'`.
- `daily_reports`: unique `uq_daily_report_branch_date (branch_id, report_date)` (schema.sql:4650), no status/reopen columns.
- 014: `can_read_money()` = staff, manager, admin, admin_viewer; `can_write_money()` = staff, manager, admin; writes `RAISE EXCEPTION ... ERRCODE '42501'`; reads are `language sql ... WHERE can_read_money()`.
- Timezone: `Asia/Kathmandu` everywhere a day is decided.
- I could not read CMD-54's trigger proof (branch not on any remote I can see). Everything about `current_user` below is **to be proven by a local test** before I rely on it (§5.3).

## 1. Tables
All new tables: RLS on, org-scoped, `practitioner` blocked by a restrictive policy, `admin_viewer` read only. No INSERT/UPDATE/DELETE grant for `authenticated` on documents, counters, settings, requests, `bs_calendar`.

### 1.1 `bs_calendar`
`ad_date date PK, bs_year int, bs_month int (1-12), bs_day int`, range CHECKs; BS 2075-01-01 to 2100 year end; global; written only by the migration. `bs_date(ad date)` returns `(bs_year, bs_month, bs_day)`; `fiscal_year(ad date)` returns `'2083/84'` (`bs_month >= 4` → `y/(y+1)%100`, else `(y-1)/y%100`). Out of range raises `BS_OUT_OF_RANGE`. STABLE. Source: §4.

### 1.2 `org_billing_settings`
`org_id PK, pan, pan_bill_mode boolean default false, mode_changed_at, mode_changed_by`. Read returns the default when no row. Only `billing_set_mode` writes.

### 1.3 `money_counters`
`(org_id, series, fiscal_year) PK, last_seq int`. Series `receipt` (receipts + refund notes), `pan_bill`, `credit_note`. Own table, so 021 does not need 019's `patient_counters`.

### 1.4 `money_documents`
Columns as brief §2.2, plus `buyer_name`, `buyer_pan` (snapshot at issue; the sales register needs them).
- **Keys (C1):** `UNIQUE (org_id, series, fiscal_year, seq)` only. `number` is **not** unique (PAN bill `1189` and `CN-14` repeat every fiscal year). `UNIQUE (org_id, series, fiscal_year, number)` as a second guard against formatting bugs.
- CHECKs: refund_note/credit_note need `related_document_id`; `total > 0`; cancelled needs reason, by, at.
- Immutability trigger (BEFORE UPDATE OR DELETE): DELETE always `DOC_IMMUTABLE`. UPDATE allowed only if all columns except `print_count`, `sent`, `status`, `cancel_reason`, `cancelled_by`, `cancelled_at` are unchanged, and `status` only moves `issued → cancelled` and only for `pan_bill`. A receipt can never be cancelled.

### 1.5 `money_requests`
`id, org_id, branch_id, kind CHECK ('refund'), document_id, booking_id, amount, note, requested_by, requested_at, assigned_to NULL, status (open|done|declined), resolved_by, resolved_at, resolution_note`. Stored in Part 0; completed by `money_refund(p_request => ...)`.

### 1.6 Additions to existing tables
- `payments.document_id uuid NULL`; `payment_refunds.document_id uuid NULL`, `payment_refunds.paid_back_by text NULL`.
- `daily_reports`: `status` (`counted|closed|reopened`, old rows backfilled `closed`), `blind_counts jsonb`, `difference_reason`, `submitted_by`, `submitted_at`, `reopened_at`, `reopened_by`, `reopen_reason`, `superseded_by uuid NULL`. `uq_daily_report_branch_date` is replaced by a partial unique index `(branch_id, report_date) WHERE superseded_by IS NULL`.

## 2. Numbering
- `money_next_number(org, series, fy)` (internal, no grants):
  `INSERT INTO money_counters (org_id, series, fiscal_year, last_seq) VALUES ($1,$2,$3, 1) ON CONFLICT (org_id, series, fiscal_year) DO UPDATE SET last_seq = money_counters.last_seq + 1 RETURNING last_seq;`
  First document of a year: the INSERT creates the row with 1. Later: the conflict path updates the row and **takes its row lock, held until the issuing transaction commits or rolls back**, so a second issuer waits and then reads the committed value. Rollback also rolls the counter back: no gap, no reuse.
  (Two first-ever concurrent inserts: the loser of the unique-index race waits for the winner's commit, then takes the DO UPDATE path. No lost update.)
- Formats: receipt mode `2083/84-1189` (receipts and refund notes share the series); PAN mode bills `1189`, credit notes `CN-14`, per fiscal year. Fiscal year from `issued_at` in Kathmandu time; counters restart at 1 on 1 Shrawan.
- One SQL formatter `money_format_number(kind, fy, seq)` and one JS helper `src/utils/moneyNumber.js`; a Vitest table and a SQL test run the same cases (parity).
- **Concurrency harness:** `scripts/money-concurrency-test.sh` (as the CMD-95 scripts): 20 separate `psql` processes (separate connections, started together with a barrier) each call `money_collect` on its own booking in one org; assert numbers are exactly `1..20`, unique, no gap. A second run: 20 calls where 5 are made to fail after the number is taken (forced error) and assert the remaining numbers are gapless. Local DB only; refuses any host other than 127.0.0.1.
- PAN mode org: `money_collect` issues a `pan_bill`; refunds issue a `credit_note`; `NOT_PAN_MODE` if a bill is asked for in receipt mode.

## 3. Functions, grants and role checks (C5, C8)
**One entry point per write.** Every public write exists as an `act_*` wrapper (012 pattern: `_act_resolve`, `_act_finish`, `action_log` with ids only) and **only the wrapper is granted to `authenticated`**. The inner function (`money_collect`, `money_refund`, ...) has `REVOKE ALL FROM PUBLIC, anon, authenticated` and is called only by its wrapper (definer owner calls it). So `action_log` cannot be skipped. Same for reads that have an action form (`day_expected`). Plain reads with no action form (sales register view, `bs_date`, `fiscal_year`) are granted directly.
All are SECURITY DEFINER, `search_path = public`; each starts with the 014 check, resolves org and branch from the caller, and checks the target rows belong to that org (RLS does not apply to definer code).

| Wrapper → inner | Role check | Notes |
|---|---|---|
| `act_money_collect` → `money_collect` | `can_write_money()` (staff, manager, admin) | §6 |
| `act_money_refund` → `money_refund` | manager, admin | reason required; amount ≤ paid − earlier refunds |
| `act_money_request_refund` | `can_write_money()` | creates a `money_requests` row |
| `act_money_request_decline` | manager, admin | |
| `act_bill_cancel` | manager, admin | PAN bill only; cancel + credit note in one transaction |
| `act_document_print` | `can_write_money()` | increments `print_count` once, returns `Original`/`Copy` |
| `act_document_send` | `can_write_money()` | appends to `sent` |
| `act_day_submit_count` | staff, manager, **admin** | returns only `{submitted:true}` (C8) |
| `act_day_expected` | manager, admin (admin_viewer read) | only reader of expected totals |
| `act_day_close` | manager, admin | blockers; difference needs reason |
| `act_day_reopen` | admin | audited |
| `act_billing_set_mode` | admin | `MODE_CHANGE_MID_YEAR` until Sadin rules |
Practitioners and agents: no grant. `admin_viewer`: reads only. Sales register: `security_invoker` view `money_sales_register`.

## 4. BS calendar source (R3)
Source: npm `nepali-date-converter` 3.4.2 (MIT, github subeshb1/Nepali-Date). **Not installed**: Sadin's approval must be typed in this session. When it is: install in the scratchpad only (not `package.json`), read its range, generate BS 2075-2100 rows, check both range edges, check-in the generated rows in the migration with the version in a comment.
Test pairs: 12, to be checked **by Sadin** against the official source named. AD values below are what I expect and are **UNVERIFIED** (from general knowledge, not from the library or the calendar); the test file marks them the same way until Sadin signs off.
| # | BS date | Expected AD | Why | Official source to check |
|---|---|---|---|---|
| 1 | 2081-01-01 | 2024-04-13 | new year | Nepal govt calendar (Ministry of Home Affairs), BS 2081 |
| 2 | 2082-01-01 | 2025-04-14 | new year | MoHA calendar BS 2082 |
| 3 | 2083-01-01 | 2026-04-14 | new year | MoHA calendar BS 2083 |
| 4 | 2081-03-32 | 2024-07-15 | day before 1 Shrawan | MoHA calendar BS 2081 (page: Asar) |
| 5 | 2081-04-01 | 2024-07-16 | 1 Shrawan (FY turn) | MoHA calendar BS 2081 |
| 6 | 2082-03-31 | 2025-07-16 | day before 1 Shrawan | MoHA calendar BS 2082 |
| 7 | 2082-04-01 | 2025-07-17 | 1 Shrawan (FY turn) | MoHA calendar BS 2082 |
| 8 | 2083-03-31 | 2026-07-16 | day before 1 Shrawan | MoHA calendar BS 2083 |
| 9 | 2083-04-01 | 2026-07-17 | 1 Shrawan (FY turn) | MoHA calendar BS 2083 |
| 10 | 2081-12-30 | 2025-04-13 | last day of Chaitra, before new year | MoHA calendar BS 2081 (Chaitra) |
| 11 | 2082-12-30 | 2026-04-13 | last day of Chaitra | MoHA calendar BS 2082 |
| 12 | 2075-01-01 | 2018-04-14 | start of the table (edge) | MoHA calendar BS 2075 |
Rows 4, 6, 8, 10, 11 depend on the true month lengths (29-32 days), which is exactly what the check is for; if the calendar disagrees I fix the expected value, not the data, and tell the lead. Fiscal-year assertions: `fiscal_year(day before 1 Shrawan)` ≠ `fiscal_year(1 Shrawan)`.

## 5. Locks (R1, C2)
**Rule: lock by money-event date**, not booking date. Event date = `(created_at AT TIME ZONE 'Asia/Kathmandu')::date` for payments and refunds, `issued_at` for documents. Branch = the booking's branch (documents carry `branch_id`). `day_is_closed(branch, date)` = a `daily_reports` row with `status='closed'` and `superseded_by IS NULL`.

### 5.1 Time cannot be chosen by the client (C2)
BEFORE INSERT triggers on `payments`, `payment_refunds`, `money_documents` **set `NEW.created_at` / `issued_at := now()`**, overriding whatever was sent. BEFORE UPDATE refuses any change to `created_at` / `issued_at` (`TIME_IMMUTABLE`). So a future or past stamp cannot dodge the lock, and an old row cannot be moved to an open day.
UPDATE/DELETE checks the day of **OLD and NEW** (for rows that carry an amount): both days must be open. DELETE of refunds and documents is refused outright; payments DELETE stays as today (booking lock) plus the day check, except rows with a `document_id`, which refuse it (D2, §5.2).

### 5.2 Per table
| Table | Today | Part 0 |
|---|---|---|
| `bookings` | any change refused when `is_locked` | unchanged, plus the single narrow exception in 5.4 |
| `payments` | refused when booking `is_locked` | direct client INSERT: still refused when the booking is locked (acceptance 5), plus refused when today's day is closed for the branch. `money_collect` path: allowed on a locked booking **when today is open** (5.3) |
| `payments` with `document_id` (D2) | n/a | **immutable for everyone**: UPDATE of `amount`, `payment_mode`, `booking_id`, `document_id` and DELETE refused (`DOC_PAYMENT_IMMUTABLE`), including definer code and the owner. Corrected only by a refund plus a refund note/credit note, like the document. Legacy rows (`document_id IS NULL`) keep today's behaviour plus the day check |
| `payment_refunds` | none | refused when the event day is closed (INSERT: today; UPDATE: OLD and NEW day) |
| `money_documents` | none | INSERT refused when today is closed (`issued_at = now()`); UPDATE/DELETE per 1.4; cancel of a PAN bill refused when today is closed (reopen first) |
| `daily_reports` | none | rows written only by the day functions |
Because `issued_at` is forced to now(), the document check only bites when the day is closed and the clinic keeps working (C9); `money_collect` checks the day **first** (§6) so no number is taken.
Side effect to confirm: cancelling an **unlocked** older booking (not paid on a closed day) when today is closed makes the auto-refund INSERT fail with DAY_LOCKED, so the cancel fails. I propose that is right (reopen first); lead to confirm.

### 5.3 How the payment trigger tells `money_collect` from a client INSERT
A SECURITY DEFINER trigger function can't tell: `current_user` inside it is always the function owner. So the check is in a **separate BEFORE INSERT trigger, SECURITY INVOKER** (`trg_payments_guard`), where `current_user` is the role that ran the INSERT:
- client direct INSERT: `current_user = 'authenticated'`;
- `money_collect` (definer): `current_user` = the function owner.
The trigger is `BEFORE INSERT OR UPDATE OF document_id` (round 3, D1). Rule: if `NEW.document_id IS NOT NULL` (INSERT) or `NEW.document_id IS DISTINCT FROM OLD.document_id` (UPDATE) and `current_user` is not the owner role → `RAISE 'DOC_PAYMENT_FORBIDDEN'`. So a client can never set or change `document_id`. Every SECURITY DEFINER function shares that owner, so `current_user` alone does not single out `money_collect`: the AFTER (definer) trigger therefore skips the booking-`is_locked` refusal **only when `NEW.document_id IS NOT NULL` AND `NEW.document_id::text = current_setting('money.doc', true)`** (the GUC `money_collect` sets in step 7, after the document exists) and today is open. Another definer function has no such document and no such GUC.
`current_user` mechanism: CMD-54 proved it on local (its `tenant-isolation.sql` §3i first check: `authenticated` for a direct write, the function owner inside a SECURITY DEFINER function, `service_role` for a service write; lead re-ran 2349 PASS). I did not read or touch that worktree. My own tests below must still prove it on this branch. A client cannot set `current_user` (it cannot `SET ROLE` to the owner). The BEFORE guard decides by `current_user` only; the AFTER lock skip and the §5.4 exception additionally need `money.doc` (a client can set a GUC, but it still fails the `current_user` test first). A forged `document_id` is also useless: the BEFORE trigger refuses it first, and the document row can't be created by a client.
Tests (local, must pass before I rely on it): client INSERT with `document_id` → refused; client UPDATE of `document_id` → refused; **another definer function (e.g. `record_membership_payment`) on a locked booking still cannot change `payment_status`** (no matching `money.doc`); a definer insert with a `document_id` but no matching GUC on a locked booking → DAY_LOCKED; client INSERT on a locked booking → DAY_LOCKED as today; `money_collect` on a locked booking, today open → ok; same with today closed → DAY_LOCKED; a client that `SET ROLE` / `set_config('money.collect', ...)` still fails. Not proven yet; CMD-54's proof was not readable to me.

### 5.4 Narrow exception on `bookings` for `payment_status`
`enforce_booking_immutability` gets one added branch at the top of its `is_locked` check:
allow when **all** hold: `current_user` is the owner role (not `authenticated`), `to_jsonb(NEW) - 'payment_status' - 'updated_at' = to_jsonb(OLD) - 'payment_status' - 'updated_at'` (nothing else changed), and `NEW.payment_status` is `derive_payment_status(...)` of the real payments sum (so it can only be the correct value), and the same transaction has a `money_documents` row with `id = current_setting('money.doc')` issued by this call (set with `set_config(..., true)` inside `money_collect` after the document is created; the GUC is only a second condition, `current_user` is the one that matters). Columns: **`payment_status` only** (and `updated_at` if a trigger touches it). `due_holder_name` is **not** in the exception: "leave as due" on a locked booking stays refused (Part 1 decides; question below).
Tests: client UPDATE of `payment_status` on a locked booking → DAY_LOCKED; `money_collect` → payment_status changes and no other column does; a definer function other than `money_collect` can't (no document in the transaction); an UPDATE changing `payment_status` and `final_amount` together → refused.
Part 1 follow-up (note for the PM): the Collect screen makes a locked-day due collectable (`api.js` ~966 comment says a locked booking can't be collected; Part 1 switches the client to `act_money_collect`).
`day_expected` and the drawer count the payment on the **event** date (today), not the booking date, and the closed day's `daily_reports` row is untouched. The existing client report code, which sums by booking, will differ from the new drawer figure for such payments: Part 3 switches it.

## 6. `money_collect` (R1, C3, C4, C9)
Today (all client-side, `src/services/api.js`): `recordPayment` (~413) per booking: plain tender → INSERT into `payments`; wallet tenders → `record_membership_payment`, `record_referral_wallet_payment`, `redeem_referral_voucher`, `record_voucher_wallet_payment` (+ `_pooled`); session package → `redeem_package_session` + a residual `payments` row. Other writers ~2084, 2178, 2289, 2778, 2913, `closeDay` (~3080/3355). **Part 0 rewires none of it**; `money_collect` is new, proved by tests; Part 1 switches the client.
Signature: `money_collect(p_lines jsonb, p_tenders jsonb, p_customer uuid, p_buyer_name text, p_buyer_pan text, p_ctx jsonb)` via `act_money_collect`.
- `p_lines`: `[{booking_id, amount}]`, explicit allocation. `p_tenders`: `[{mode, amount, package_id?}]`; **sum(tenders) must equal sum(lines)** (`TENDER_MISMATCH`).
- Tender modes: `cash`, `card`, `fonepay`, `other`, and `session_package` (calls `redeem_package_session` + residual row as today). **Any wallet tender (membership, voucher, referral) → `UNSUPPORTED_TENDER`**; the existing wallet RPCs stay untouched (C3).
- Order, all in one transaction (round 3, D1): (1) 014 check; (2) load all bookings `FOR UPDATE`, same org; (3) `MIXED_BRANCH`, `MIXED_CUSTOMER`, `OVERPAY` (a line above that booking's due = `final_amount − paid`) checks; (4) **`DAY_LOCKED` if today is closed for the branch (before any number is taken, C9)**; (5) compute the document's lines (one per booking: `label, amount, ref`), total and method summary from `p_lines`/`p_tenders`, no insert yet; (6) take the number and **insert the document**; (7) `set_config('money.doc', <document id>, true)`; (8) **insert the payments rows WITH `document_id`** (and run the package redemption). No UPDATE of `payments` ever follows, so `document_id` is set at INSERT time and the §5.3/§5.4 conditions can see it. A refusal at any step rolls back, so no number is used.
- Locked booking and today open: allowed (R1). The payment, the receipt and the drawer are dated today; the booking keeps its old day and old closing.
- One receipt per call. Several bookings = one receipt, one line each (accepted).

## 7. Cancel of a paid booking (R2)
Part 0: `handle_booking_cancellation_refund` **unchanged**.
For the manager/admin path (as accepted): when the booking already has a `money_documents` receipt, a refund note (credit note in PAN mode) is also created by a system actor (`issued_by_name = 'System (booking cancelled)'`, `issued_by = auth.uid()`). **This is Part 1**, not Part 0, together with the front desk behaviour.
**Part 1 follow-up (for the PM to ticket):** front desk cancelling a paid booking creates a `money_requests` refund row for a manager and does **not** refund; manager/admin cancelling refunds and issues the refund note or credit note. Needs the cancel path to be an action (`act_booking_set_status` exists from 012/014) that branches on role. Part 0 only provides `money_requests`.

## 8. Blind count and closing (C7)
- `act_day_submit_count` (staff, manager, admin) stores counts per method (status `counted`), re-submittable before close, and returns exactly `{"submitted": true}` for **every** role: no expected amounts, no differences, no totals, not even on error.
- Errors raised to staff (`act_day_expected`, `act_day_close`, `act_day_reopen`) are `42501` with a fixed message (`MONEY_FORBIDDEN`), never containing an amount, count or day total. `DAY_LOCKED`/`NOT_FOUND` messages carry no figures. A test greps every staff-visible error and return value for digits from the seeded totals.
- `day_close`: blockers (visit in chair, completed visit neither paid nor left as due, open QR/link = empty until Part 5) return as a list and refuse closing; any difference between counted and expected needs `difference_reason`. Expected per method = payments with **event date = that day** minus `paid_back_by` refunds by cash. Existing report columns are kept so current screens keep working.
- Reopen: admin, with reason, audited: `status='reopened'`, bookings unlocked, old row kept (`superseded_by` on the new close).

## 9. Rollback (C10)
`migration-021-rollback.sql`, in this order: drop lock/guard triggers and restore the pre-021 `update_booking_payment_status` and `enforce_booking_immutability` bodies → drop `act_*` wrappers and inner functions, the view → drop **`payments.document_id` and `payment_refunds.document_id` (and `paid_back_by`) first**, so no FK points at `money_documents` → drop `money_requests`, `money_documents`, `money_counters`, `org_billing_settings`, `bs_calendar` and the BS functions → drop the added `daily_reports` columns and restore `uq_daily_report_branch_date` (fails if reopen history created duplicate day rows: the rollback first keeps the latest row per day).
Proof on local: (a) `pg_dump --schema-only` diff before 021 vs after rollback is empty; (b) row counts **and** an `md5` over ordered rows of `payments`, `payment_refunds`, `daily_reports` (old columns only) before 021 and after rollback are equal. Rows created after 021 lose their `document_id` and extra data on rollback: stated, rehearsal-only; on prod after real receipts exist, a rollback needs a lead decision.

## 10. Tests
- test:rls: other org sees nothing; practitioner and admin_viewer can't call any write; staff can't refund, close or reopen, and never receives expected amounts (before or after submit); a closed day refuses each write kind (payment, refund, document, cancel of a PAN bill); documents can't be updated outside the allowed columns or deleted; client INSERT with a future `created_at` is forced to now(); a payment with `document_id` refuses UPDATE (each of the four columns) and DELETE for client, definer and owner (D2); legacy payment rows (NULL `document_id`) behave as today; `created_at` UPDATE refused; §5.3 and §5.4 tests.
- Numbering: the §2 harness (20 concurrent, rollback gapless), 1 Shrawan turnover.
- `money_collect`: OVERPAY, MIXED_BRANCH, MIXED_CUSTOMER, TENDER_MISMATCH, UNSUPPORTED_TENDER, DAY_LOCKED without number consumed, old due on a locked booking paid today.
- Vitest: action mapping, number formatting per mode, parity.
- Merge glue: copy the fix from PR #27 (search "merge glue") when step 2 starts (the 78/79 seeds clash on `users.dentist_id`).

## 11. Decided (lead, round 3) and PM follow-up list
1. Cancelling an unlocked older booking while today is closed: **refused with DAY_LOCKED until reopen** (a closed day means the clinic stopped taking money for it). Part 1 follow-up: the cancel screen must show this refusal plainly.
2. "Leave as due" on a locked booking (`due_holder_name`): **stays refused in Part 0**; Part 1 decides.
3. Sadin signs off the pairs; the npm install approval must be typed in this session.
PM follow-ups (Part 1): collectable locked-day dues (§5.4); front desk cancel creates a refund request (§7); items 1 and 2 above.

## 12. Not verified
- BS converter data, its range, and every pair in §4 (not installed; the expected AD values are from memory).
- The `current_user` approach in §5.3 and the booking exception in §5.4: not run (no SQL); CMD-54 proved the `current_user` idea on its branch (per the lead), mine is still to be proven.
- IRD rules (general knowledge only).
- Prod matches `schema.sql` for `daily_reports`, locks and payment triggers (CMD-11).
- `api.js` line numbers (carried from the earlier session).
- Receipt layout and VAT wording (Sadin's decision, not legally checked).
- Nothing was run against any database.

## 13. Build notes (what the SQL does that the note left open, or does differently)
Added after the build, for the lead's QC. Each is a decision I made; say if you want it otherwise.
1. **Refunds with no recorded method** (legacy rows, and the automatic cancellation refund) are treated as **cash** in `day_expected` and in the day-close totals. Alternative: a separate "unspecified" line, but then every cancel day would need a difference reason.
2. **Mid-year rule** for `billing.set_mode`: refused when the organisation has issued any document in the current fiscal year (not "after month X"). Changing the PAN alone is allowed.
3. **Blind count rows** are `daily_reports` rows with `status='counted'` (`closed_by`/`closed_at` are now nullable). The current report screens list `daily_reports` rows, so a counted day would show there until Part 3 switches them; nothing calls the count function yet.
4. **`day_close` totals** (`cash_total`, `card_total`, `fonepay_total`, `net_revenue`) count payments by the day they were taken (event date), wallet modes and SessionPackage excluded, same buckets as `getDailySummary`. Old screens sum by booking day, so a due paid late shows on a different day there. Voucher and membership/package product sales are not in Part 0's expected amounts (Part 6, packages).
5. **A refund with no receipt** (legacy payments) is recorded without a note: a refund note must point at a receipt.
6. **`money_collect` zero-balance settle** (api.js writes a 0 payment when nothing is owed) is not reproduced; lines must be positive.
7. **Old closeDay in the client** keeps working: new `daily_reports` rows default to `status='closed'`. A day with a count row but no close makes the old client say ALREADY_CLOSED (it checks for any row).
8. **Payment time:** owner-context inserts (migrations, seeds, definer code) may still stamp history; any client role gets `now()`.
9. **`act_day_submit_count` returns `{"submitted": true}` only**; the audit row keeps the branch (not in the returned data).
10. **action.log inputs** hold ids only (booking ids, document id, branch, date), never amounts.
11. **Session package tender**: one booking per call; the tender amount is what the caller says (the client's old "residual" is the caller's job now).
12. The migration has **no bs_calendar rows**. `fiscal_year()` raises `BS_OUT_OF_RANGE` until they are added, so no real document can be issued yet. The tests use throwaway rows with `bs_year` 2999 (lead's conditions).
