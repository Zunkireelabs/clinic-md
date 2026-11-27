# Brief: Record service-SMS consent for new bookings · CMD-93

**Status:** ready to build, 2026-11-22 · **Phase:** 2 · **Parent:** CMD-81 · **Lead:** lead session
**Follows:** `docs/briefs/hub-data-model.md` §9 (consent decided by Sadin 2026-11-22), migration 013 (`patient_channels`,
`hub_backfill_booking_consent`), CMD-59 (legal check).

## 1. What and why

Migration 013 backfilled service-SMS consent (`agreed`, `source = booking`) for patients who had **already** booked.
A patient who books **after** 013 gets no row, so the Follow-up agent would refuse to confirm their booking
(`NO_CONSENT`). Sadin decided (2026-11-22): record it at booking time, the same rule as the backfill.

013's switch (`hub.backfill_booking_consent`) is a setting read once while the migration runs. A trigger needs a
**lasting, per-clinic** switch, so legal (CMD-59) can turn the rule off for a clinic without a deploy. Settings ›
Channels will show it later (its own ticket); this ticket adds no screen.

## 2. Where to work

- Worktree from the CMD-83 branch (the top of the stack):
  `git worktree add ../clinic-md-CMD-93 -b feature/CMD-93-booking-consent origin/feature/CMD-83-money-definer-guard`
- **Migration 015** is claimed (011 #15, 012 #16, 013 #17, 014 #18). The PR will target
  `feature/CMD-83-money-definer-guard` (#18).
- Local Supabase only; apply by hand with psql (CMD-85).

## 3. What to build (migration 015)

1. **The switch:** `organizations.booking_phone_is_service_consent boolean NOT NULL DEFAULT true`. A comment on the
   column says what it means and cites CMD-59.
2. **The trigger:** `AFTER INSERT ON public.bookings`, plus `AFTER UPDATE OF customer_id` (a booking that gets its patient
   later). It calls a `SECURITY DEFINER` function, `SET search_path = public`, with EXECUTE revoked from PUBLIC, anon and
   authenticated. The function:
   - finds the booking's patient and org (through the branch), and does nothing if the patient has no phone, the phone
     doesn't normalise (`normalize_phone_e164`), or the org's switch is false;
   - inserts `patient_channels (org_id, customer_id, 'sms', address, 'service', 'agreed', 'booking', now(), evidence)`
     with `ON CONFLICT (org_id, channel, address, purpose) DO NOTHING`, so it **never** changes an existing row (never a
     `stopped` one, never one a person recorded) and **never** marketing;
   - evidence: `'Phone given when booking ' || booking_number`;
   - never fails the booking: wrap the body so any error becomes a `RAISE WARNING`, and the booking insert succeeds.
3. **Patient phone changes:** out of scope (a new number gets a row at the patient's next booking). Say so in a comment.
4. **Rollback:** drops the trigger, the function and the column. It leaves the `patient_channels` rows it created, and
   says so in a comment (they're indistinguishable from backfill rows only by evidence text).

## 4. Tests (`supabase/tests/tenant-isolation.sql`)

- A new booking for a patient with a phone and no row → one `agreed` service-sms row, `source = booking`.
- The patient already `stopped` → still `stopped` after a new booking; no new row.
- Marketing is never created.
- The org's switch is false → no row.
- A patient with no phone or an unparseable phone → no row, and the booking succeeds.
- The public booking flow (`anon` path, through the existing `public_*` booking function) also creates the row.
- The trigger function isn't executable by anon or authenticated.

## 5. Acceptance checks (the lead runs these)

1. 015 applies after 014, rolls back cleanly, and re-applies.
2. `test:rls` passes with the new cases, and fails if the trigger is dropped (show it). `npm test` and `npm run build` pass.
3. In the browser (agent-browser, staff@, local): create a booking for a new patient with a Nepali mobile number; the
   row appears. Book through the customer booking flow too; the row appears.
4. The diff touches only 015 + rollback + tests.

## 6. Not in scope

The Settings screen for the switch; consent wording shown to patients; WhatsApp/email consent; phone-number changes.

## 7. Handoff

DEV-APPROACH template, ending with **Not verified**. Say that 015 is **not applied to prod** and needs 011–014 first.
