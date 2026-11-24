# Design note: Money Part 0 (data) · CMD-115 · migration 021

Status: DRAFT for lead review. **No SQL written.** Builder session, 2026-11-24. Brief: `docs/briefs/money.md` §2, §3.
Base: `feature/CMD-97-playbooks-new-orgs` + merge of CMD-79 (011). Local DB only. Does not depend on 019 or 020.
Migration number 021 is being claimed on CMD-115 by the PM (not yet confirmed to me).

## 0. Facts found on this branch (so the design starts from what exists)
- `payments(id, booking_id, amount, payment_mode, recorded_by, notes, created_at)`: no org, branch or date column (branch comes via the booking). Trigger `trg_payment_update_booking_status` (definer) already refuses INSERT/UPDATE/DELETE when the booking `is_locked` (DAY_LOCKED). So payments are locked per booking today.
- `payment_refunds(id, booking_id, org_id, amount, refunded_by, reason, created_at)`: no lock check. Trigger `handle_booking_cancellation_refund` inserts a full refund when a paid or partial booking is cancelled.
- `daily_reports(id, branch_id, report_date, totals, unpaid_count, closed_by, closed_at, is_locked)`.
- Discounts are columns on `bookings` (`discount_amount`, `discount_status`, ...), so `enforce_booking_immutability` (blocks any change when `is_locked`) already covers them. No separate discounts table to lock.
- 014: `can_read_money()` = staff, manager, admin, admin_viewer. `can_write_money()` = staff, manager, admin. Write functions `RAISE EXCEPTION ... USING ERRCODE='42501'`; read functions are `language sql` with `WHERE public.can_read_money()`. Part 0 follows this and loosens nothing.
- Timezone: dates in the schema are `Asia/Kathmandu`. Every "which day" decision below uses it.

## 1. Tables

All new tables: RLS on, org-scoped, `practitioner` blocked by a restrictive policy (as `daily_reports` does today), `admin_viewer` read only. Writes only through definer functions; no INSERT/UPDATE/DELETE policy for `authenticated` on documents, counters, settings (reads only).

### 1.1 `bs_calendar`
`ad_date date PK, bs_year int, bs_month int (1-12), bs_day int`, CHECKs on ranges. Covers BS 2075-01-01 to 2100-12-end. Global table (no org). Read-only for everyone signed in; written only by the migration. Index on `(bs_year, bs_month, bs_day)`.
Functions: `bs_date(ad date) returns bs_calendar` row-ish (`bs_year, bs_month, bs_day`) and `fiscal_year(ad date) returns text` = `'2083/84'`: if `bs_month >= 4` then `bs_year || '/' || right((bs_year+1)::text, 2)` else `(bs_year-1) || '/' || right(bs_year::text, 2)`. Dates outside the table raise `BS_OUT_OF_RANGE` (never guess). Both `STABLE`, `search_path = public`.
Source: **pending Sadin** (see §4).

### 1.2 `org_billing_settings`
`org_id uuid PK -> organizations, pan text NULL, pan_bill_mode boolean default false, mode_changed_at, mode_changed_by`. Seeded lazily (a read returns the default when no row). Only `billing_set_mode` writes it.

### 1.3 `money_counters`
`(org_id, series text, fiscal_year text) PK, last_seq int`. Series: `receipt` (shared by receipts and refund notes), `pan_bill`, `credit_note`. Same shape as `patient_counters` in 019, but defined here so 021 does not depend on 019.

### 1.4 `money_documents`
Columns exactly as brief §2.2: `id, org_id, branch_id, kind (receipt|refund_note|pan_bill|credit_note), series, fiscal_year, seq, number text, customer_id, booking_ids uuid[], lines jsonb, total numeric(12,2), method_summary jsonb, issued_by, issued_by_name, issued_at, bs_date text, related_document_id, status (issued|cancelled), cancel_reason, cancelled_by, cancelled_at, print_count int default 0, sent jsonb default '[]'`.
- `UNIQUE (org_id, series, fiscal_year, seq)` and `UNIQUE (org_id, number)` per series.
- CHECK: `credit_note`/`refund_note` require `related_document_id`; `total > 0`; `status='cancelled'` requires `cancel_reason`, `cancelled_by`, `cancelled_at`.
- `buyer_pan text NULL` and `buyer_name text` columns added (the sales register needs buyer and buyer PAN; a snapshot at issue time, not a join).
- Immutability trigger (BEFORE UPDATE OR DELETE): DELETE always refused (`DOC_IMMUTABLE`); UPDATE allowed only if every column other than `print_count`, `sent`, `status`, `cancel_reason`, `cancelled_by`, `cancelled_at` is unchanged, and the `status` move is only `issued -> cancelled` and only for `pan_bill`. A receipt can never be cancelled (corrected only by a refund note). Direct DML by `authenticated` is not granted anyway; the trigger also protects definer code and the table owner role used by tests.
- Immutability trigger applies to `service_role`/owner too (no `session_replication_role` carve-out in functions).

### 1.5 `money_requests`
`id, org_id, branch_id, kind text CHECK (kind IN ('refund')), document_id, booking_id, amount numeric, note, requested_by, requested_at, assigned_to uuid NULL (a manager of the branch), status (open|done|declined), resolved_by, resolved_at, resolution_note`. Part 0 stores them and offers `request_refund`; completing one is done by `money_refund` (sets the request `done` when `p_request` is passed). Declining: `money_request_decline` (manager, admin).

### 1.6 Additions to existing tables
- `payments.document_id uuid NULL -> money_documents` (nullable: old rows stay unchanged).
- `payment_refunds.document_id uuid NULL`, `payment_refunds.paid_back_by text NULL` (method the money went back by: cash, fonepay, card, other, validated against the master-data methods when present).
- `daily_reports`: `reopened_at, reopened_by, reopen_reason, superseded_by uuid NULL`, plus `status text` (`counted | closed | reopened`) and `blind_counts jsonb` (method -> counted), `difference_reason text`, `submitted_by, submitted_at`. Existing rows backfill as `closed`. Existing `UNIQUE (branch_id, report_date)` (to be confirmed on the file) must be relaxed to "one row where `superseded_by IS NULL`" so reopen can keep history.

## 2. Numbering
- `money_next_number(org, series, fy)` (internal, definer, no grants): `INSERT INTO money_counters ... ON CONFLICT (org_id, series, fiscal_year) DO UPDATE SET last_seq = money_counters.last_seq + 1 RETURNING last_seq`. The row lock serialises concurrent issuers. Because it runs inside the issuing transaction, a rollback also rolls the counter back: no gap, no reuse (this is what the "rolled-back collect uses no number" test proves).
- Printed formats:
  - receipt mode: receipts and refund notes share series `receipt`: `2083/84-1189`.
  - PAN bill mode: bills `1189` (series `pan_bill`, per fiscal year), credit notes `CN-14` (series `credit_note`).
- Fiscal year = `fiscal_year(issued_at AT TIME ZONE 'Asia/Kathmandu')::date`. Turns over at 1 Shrawan (BS month 4, day 1), counters restart at 1.
- Documents are never deleted; a rolled-back transaction leaves nothing.
- Formatting lives in one SQL function `money_format_number(kind, fy, seq)` and a matching JS helper (`src/utils/moneyNumber.js`) with Vitest cases per mode. A test asserts both agree on a table of cases.
- Receipt-mode org that has `pan_bill_mode=false`: PAN bills cannot be issued (`NOT_PAN_MODE`). PAN-mode org: `money_collect` issues a `pan_bill` instead of a `receipt`; refunds issue a `credit_note` (not a refund note), linked to the bill.

## 3. Functions and role checks (compared with 014)

All are `SECURITY DEFINER, SET search_path = public`, revoked from PUBLIC and anon, granted to `authenticated`. Each starts with the 014 check, then resolves the caller org and branch and checks the target row belongs to it (tenant scoping in the function, RLS is not enough for definer code). Failure: `RAISE EXCEPTION ... USING ERRCODE='42501'` (same as 014).

| Function | Check | Notes |
|---|---|---|
| `money_collect(p_booking_ids, p_tenders jsonb, p_customer, p_buyer_pan, p_ctx)` | `can_write_money()` (staff, manager, admin) | see §6 |
| `money_refund(p_booking, p_amount, p_reason, p_paid_back_by, p_request, p_ctx)` | role in (manager, admin) | amount <= paid - earlier refunds, reason required, one transaction with the refund note / credit note |
| `money_request_refund(p_document, p_amount, p_note, p_ctx)` | `can_write_money()` | staff creates, assignee = manager on duty or NULL; managers/admin may too but normally refund directly |
| `money_request_decline(p_request, p_note)` | manager, admin | |
| `bill_cancel(p_document, p_reason, p_ctx)` | manager, admin | PAN bill only; cancels and issues credit note in the same transaction |
| `document_print(p_document)` | `can_read_money()` AND not admin_viewer for write (print_count is a write) -> `can_write_money()` | returns `{label:'Original'|'Copy'}`, increments `print_count` in one `UPDATE ... RETURNING` |
| `document_send(p_document, channel, to)` | `can_write_money()` | appends to `sent` |
| `day_submit_count(p_branch, p_date, p_counts jsonb)` | staff, manager | returns only `{submitted:true}`; never expected amounts |
| `day_expected(p_branch, p_date)` | manager, admin (and admin_viewer read) | the only reader of expected totals |
| `day_close(p_branch, p_date, p_difference_reason)` | manager, admin | blockers list; difference needs reason |
| `day_reopen(p_branch, p_date, p_reason)` | admin only | audited |
| `billing_set_mode(p_pan, p_mode)` | admin only | refuses mid fiscal year: `MODE_CHANGE_MID_YEAR` |
| `day_is_closed(p_branch, p_date)` | internal (no grants) | used by the lock triggers |
| `money_check_blockers(p_branch, p_date)` | internal; exposed via `day_close` | |

Every public write is wrapped by its `act_*` action (012 pattern: `_act_resolve`, `_act_finish`, `action_log` with ids only). Action keys: `money.collect`, `money.refund`, `money.request_refund`, `bill.cancel`, `document.print`, `document.send`, `day.submit_count`, `day.close`, `day.reopen`, `billing.set_mode` (as brief §2.5). Practitioners and agents have no grant. `admin_viewer` gets read only through `can_read_money()`.
Read helpers: sales register is a `security_invoker` view `money_sales_register` (PAN bills and credit notes, cancelled included; number, BS date, buyer, buyer PAN, amount, status), with RLS on the base table doing the org scope.

## 4. BS calendar source
**Source pending Sadin.** Candidate: npm `nepali-date-converter` 3.4.2 (MIT, github subeshb1/Nepali-Date). The lead reports Sadin said yes, but I only accept approvals typed in my own session, so I have NOT installed it. When Sadin types it here I will install it in the scratchpad only (not `package.json`), read its covered range, generate the rows (BS 2075-2100), and check the range edges.
Test pairs (>= 10): each must name an official source; I will not invent pairs from the library itself (that would only test it against itself). Needed set:
1. 1 Baisakh of two different years (new year).
2. Both sides of 1 Shrawan (31 Asar and 1 Shrawan) for two different years (fiscal year turn).
3. Both sides of a BS year end (last day of Chaitra and 1 Baisakh).
4. A 32-day month and a 29-day month.
Official source candidates: Nepal government calendar (Nepal Rastriya Panchanga, Ministry of Home Affairs) and published government holiday lists. **Who checks the pairs against the official calendar? (needs a human named, lead question 1.)** Until then pairs are marked `UNVERIFIED` in the test file and in the ticket, and the label `needs-verification` stays.

## 5. Locks, per table
"Day" = `(timestamp AT TIME ZONE 'Asia/Kathmandu')::date`, branch = the booking's branch.
| Table | Today | Part 0 |
|---|---|---|
| `bookings` | `enforce_booking_immutability` blocks when `is_locked` | unchanged (also covers discounts) |
| `payments` | refused when booking `is_locked` | keep, **plus** refuse when `day_is_closed(branch, payment day)`, for INSERT, UPDATE, DELETE. A payment for a booking on an open day is allowed even if other days are closed. |
| `payment_refunds` | none | BEFORE INSERT/UPDATE/DELETE: refuse when the day is closed (day of `created_at`, or of the booking for UPDATE/DELETE; DELETE refused outright) |
| `money_documents` | none | BEFORE INSERT: refuse when the day of `issued_at` is closed for the branch. UPDATE/DELETE: the immutability trigger above (print/send/cancel are not "day" writes; cancel of a PAN bill on a closed day is refused: it needs the day reopened) |
| `daily_reports` | none | INSERT only through `day_close`; UPDATE only by reopen/close functions |
Error code: `DAY_LOCKED` (same text as today). The "today" path is not weakened: existing `is_locked` checks stay.
Order matters: the close function sets `daily_reports.status='closed'`, bookings `is_locked`, and the lock triggers read `daily_reports` (superseded_by IS NULL AND status='closed'), so reopen = set `status='reopened'`, unlock bookings, which re-opens everything at once.

## 6. `money_collect` vs the current collect path
Today (all client-side, `src/services/api.js`): `recordPayment` (about line 413) handles tenders per booking:
- plain tender: INSERT into `payments` directly;
- membership wallet: RPC `record_membership_payment`;
- referral wallet: `record_referral_wallet_payment`, `redeem_referral_voucher`;
- voucher wallet: `record_voucher_wallet_payment` (+ `_pooled`);
- session package: RPC `redeem_package_session`, plus a residual `payments` row.
Other writers: ~2084, 2178, 2289, 2778, 2913 (discounts, dues, reports), `closeDay` (~3080; the brief says 3355 on newer code) writes `daily_reports` and locks bookings from the client; report code reads payments by booking.
**Part 0 does not rewire any of this.** `money_collect` is a new function; Part 1 switches the client.
Scope proposed for Part 0:
- plain tenders (cash, card, fonepay, other) inserted as `payments` rows with `document_id`;
- wallet tenders by calling the existing 014-guarded functions inside the same transaction (one call = one transaction, so a failed wallet leaves no receipt and no number);
- session-package tenders by calling `redeem_package_session` and the residual row the same way;
- one receipt per call. **Several bookings in one call produce one receipt with one line per booking** (proposal; decision question 4).
- Part 0 proves it on local with tests only.

## 7. Cancellation auto-refund (`handle_booking_cancellation_refund`)
Proposal: keep the trigger as is (no behaviour change for the existing screens), but when the org already issues documents (a `money_documents` receipt exists for the booking) the trigger also creates the refund note (or credit note in PAN mode) as a system actor, using a dedicated `issued_by_name = 'System (booking cancelled)'` and `issued_by = auth.uid()`. If there is no receipt for the booking (legacy payments), no document is created and nothing changes. Needs lead decision (question 2).

## 8. Blind count and closing
- `day_submit_count` stores counted amounts per method in `daily_reports` (status `counted`) and returns no expected values. Re-submitting before close replaces the counts.
- `day_expected` (manager/admin) returns expected per method: payments by method for that branch and day, minus cash refunds, plus nothing else. Cash refunds (`paid_back_by='cash'`) reduce the drawer.
- `day_close` computes differences (counted - expected) per method; any non-zero needs `p_difference_reason`; blockers (visit in chair, completed visit neither paid nor left as due, open QR / link placeholder returning empty until Part 5) are returned as a list and refuse closing.
- `daily_reports` keeps today's columns (gross, discounts, net, cash/card/fonepay totals, `unpaid_count`) so the existing report screens keep working.
- Which roles may read expected amounts: manager, admin (and admin_viewer read-only). Staff: none (question 6).

## 9. Rollback (`migration-021-rollback.sql`)
Drop in reverse: lock triggers on `payments`/`payment_refunds` (restore the pre-021 payment trigger body), the new functions and actions, the view, `money_requests`, `money_documents`, `money_counters`, `org_billing_settings`, `bs_calendar` + functions; drop the added columns from `payments`, `payment_refunds`, `daily_reports`; restore the old `daily_reports` unique constraint. Existing rows in the old columns stay unchanged. Round-trip test on local: apply, roll back, `pg_dump --schema-only` diff against before-021.
Data loss on rollback: documents, counters and requests created after 021 are deleted. Rollback is for local/rehearsal; on prod, rolling back after real receipts exist would need a lead decision.

## 10. Tests (as brief §2.6)
- test:rls: other org sees nothing; practitioner and admin_viewer can't call any write; staff can't refund, close or reopen; staff never gets expected cash before submitting the count (and never after); a closed day refuses each write kind; documents can't be updated (outside the allowed columns) or deleted.
- Numbering: gapless under 20 concurrent `money_collect`; a rolled-back collect uses no number; fiscal year turns at 1 Shrawan (uses the BS pairs).
- Vitest: action mapping, number formatting per mode, JS/SQL formatting parity.
- **Merge glue:** the 78/79 seeds clash on the unique `users.dentist_id` in `tenant-isolation.sql`; copy the fix from PR #27 (search "merge glue") when step 2 starts.

## 11. Open questions for the lead (with my default)
1. BS source: approved by Sadin per the lead, waiting for his typed approval here. Who checks the pairs against an official calendar?
2. Cancellation auto-refund also creates a refund/credit note? Default: yes, only when the booking already has a document; system actor.
3. Lock by which date? Default: payment day = `created_at` in Asia/Kathmandu; the booking's `is_locked` stays, so a due on a closed day cannot be settled later without a reopen (**is that intended?**).
4. `money_collect` scope: plain + wallet tenders + package residual; several bookings = one receipt, one line each.
5. Mid-year PAN switch stays refused; product text never says "IRD-compliant" (brief §5).
6. Expected amounts readable by manager and admin only; staff gets `{submitted:true}`.

## 12. Not verified
- BS converter data, its range, and every AD<->BS pair (not installed yet).
- IRD rules (general knowledge only).
- That prod has `daily_reports`, the lock trigger and payment triggers exactly as `schema.sql` shows (CMD-11).
- The `UNIQUE (branch_id, report_date)` constraint on `daily_reports` (I believe it exists; to confirm on the file before SQL).
- Line numbers in `api.js` (from the earlier session, not re-read now).
- Receipt layout and VAT wording (Sadin's decision, not legally checked).
- Local DB behaviour of any of this: nothing was run, no SQL exists.
