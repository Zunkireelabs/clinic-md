# Brief: Staff PINs hashed, attempt limit, no PIN readable · CMD-62 · migration 022

Lead session, 2026-11-24. Groundwork (data, functions, security). No screen changes beyond what the login form already does.

## Why (found by the lead on local, from the #22 schema)
- `users.pin` is **plain text**. `login_with_pin` and `verify_pin` compare `u.pin = p_pin`.
- Column privileges: `authenticated` (and `anon`) have SELECT on `users.pin`. RLS lets **manager, admin and admin_viewer read every
  user row in their org**, so they can read colleagues' PINs. An `admin_viewer` (read-only) can read the owner's PIN and log in as
  the owner. This is a privilege escalation. Treat it as high.
- `list_discount_approvers()` filters on `u.pin IS NOT NULL AND u.pin <> ''`.
- Login: `LoginForm.jsx` calls the `pin-login` edge function, which returns an email OTP. **Its source is not in this repo**; a copy is in
  `~/Projects/bookX/supabase/functions/pin-login`. Which version runs in ClinicMD's prod is UNVERIFIED.
- Discount approval does NOT use the PIN today: the approver approves while logged in (`api.js` ~2513). So "check the hash at discount
  approval" in the ticket text has nothing to attach to. Don't invent a PIN step there. Note it in the design.

## Where
New worktree `~/Projects/clinic-md-CMD-62`, branch `feature/CMD-62-staff-pin` from `origin/feature/CMD-97-playbooks-new-orgs` (#22),
then merge `origin/feature/CMD-79-practitioner-access` (011), as CMD-54 did. **Migration 022** (021 = CMD-115). Local DB only, on a private
clone DB (not the shared `postgres` DB, which has 019 applied and is used by others). Don't depend on 019, 020 or 021.

## Build
1. `users.pin_hash text` (bcrypt via pgcrypto `crypt(p, gen_salt('bf', 10))`), `pin_failed_count int default 0`, `pin_locked_until timestamptz`.
   Backfill: hash every non-empty `pin`, then **NULL the `pin` column** in the same migration. Keep the column for one release (old
   clients) but REVOKE SELECT/UPDATE on `users.pin` and `users.pin_hash` from anon and authenticated (column-level). Writes only through
   a function.
2. `login_with_pin` / `verify_pin`: compare with `crypt(p_pin, pin_hash)`, keep the same return shapes, and the same generic error for a
   wrong email, a wrong PIN and a locked account (no account probing).
   Attempt limit: 5 failures → locked 15 min. A success resets the counter. Use the same wording for locked and wrong.
   Constant-ish work: still run `crypt` against a dummy hash when the email doesn't exist.
3. `set_my_pin(p_current_pin, p_new_pin)` (self) and `admin_reset_pin(p_user)` (admin only, same org, audited via the 012 action layer
   as `user.reset_pin`, ids only). PIN format 4-6 digits. Refuse trivial PINs (all the same digit, 1234/123456).
   Check: is there any screen today that sets `users.pin` directly? If so, list it. It will break after the REVOKE, so say how it moves
   to `set_my_pin` (minimal client change is OK, it isn't a new design).
4. `list_discount_approvers()` filters on `pin_hash IS NOT NULL`.
5. pin-login edge function: copy the bookX version into `supabase/functions/pin-login` only if it calls `login_with_pin`/`verify_pin` and
   never reads `users.pin` itself. Diff it and report what it does. If it reads the column directly, change it to call the function.
   The prod deploy is a human step: put it in the PR notes.

## Design checkpoint
Send a short design note (`docs/briefs/CMD-62-design.md` on the branch) before SQL: columns and grants, the functions with their role
checks, the lockout rule, the backfill, the rollback (it can't restore plain PINs: say so, and that rollback leaves hashes and keeps
`pin` NULL), every caller of `users.pin` in src/ and supabase/functions/, and what the pin-login function does. The lead approves above 9/10.

## Tests
- test:rls: no role (anon, staff, practitioner, manager, admin, admin_viewer) can SELECT `pin` or `pin_hash` of any user, including their own;
  the right PIN logs in, a wrong one doesn't; 5 wrong → locked even with the right PIN; unlock after the window (fake the time with an UPDATE as
  postgres); the same error text for unknown email / wrong PIN / locked; admin_reset_pin is admin-only and same-org; set_my_pin needs the current PIN.
- Backfill: after 022 no row has a non-NULL `pin`; every former PIN verifies against its hash.
- npm test (report the Test Files line), npm run build, test:rls on 001-018+022 clean, the rollback round trip.

## Production notes (hand-off)
- 022 after 011-021 as merged. Deploy pin-login from this repo after 022. Tell staff nothing changes for them.
- Before applying: a human checks that no prod process reads `users.pin` directly (CMD-11 lists unknowns).

## Not verified (lead)
- The prod `pin-login` source and version. Whether prod has the same column grants (CMD-11). Whether any clinic uses PIN login today.
