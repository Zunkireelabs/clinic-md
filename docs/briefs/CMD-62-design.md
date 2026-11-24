# CMD-62 design note: staff PINs hashed, attempt limit, no PIN readable (migration 022)

Builder, 2026-11-24. Step 1 of the brief (`docs/briefs/CMD-62-staff-pin.md`, in the lead's checkout). No SQL written yet. Branch
`feature/CMD-62-staff-pin` = `origin/feature/CMD-97-playbooks-new-orgs` + merge of `origin/feature/CMD-79-practitioner-access` (011). The merge
conflicted only in `tenant-isolation.sql`; I took the resolution CMD-54 already made for the same two parents (`603938b`).

Everything below was read from the code and from the local shared DB (read-only). Nothing about production is verified.

## 1. What I found (facts, checked)

| Finding | Where |
|---|---|
| `users.pin text`, plain. | `schema.sql:2162` |
| Only three DB objects read it: `login_with_pin`, `verify_pin` (both `u.pin = p_pin`), `list_discount_approvers` (`pin IS NOT NULL AND <> ''`). No views, no triggers on `users`. | local DB, `pg_proc` / `pg_views` / `pg_trigger` |
| `login_with_pin` and `verify_pin` are EXECUTE for `service_role` only (009). `list_discount_approvers` is EXECUTE for `authenticated`. | local DB |
| **`anon` and `authenticated` hold table-level ALL on `public.users`**, so a column-level `REVOKE SELECT (pin)` does nothing by itself. Fixing it that way means `REVOKE SELECT ON users` and re-granting an explicit column list. | local DB, `information_schema.table_privileges` |
| `users` has only SELECT policies (own row; manager/admin branch; manager org; admin_viewer org). **No INSERT/UPDATE/DELETE policy**, so no client can write `users.pin` today. The leak is read-only: manager/admin/admin_viewer read colleagues' PINs. | `rls.sql`, `pg_policies` |
| **No screen or edge function in this repo writes `users.pin`.** Nothing in `src/` writes `users` at all. The only writer of a PIN is something outside this repo (hand SQL, another app, an admin script). Which one: UNVERIFIED (CMD-11). | grep `src/`, `supabase/functions/` |
| `src/contexts/AuthContext.jsx:93` reads `users` with `select('*, branches..., organizations...')`. A column-grant fix would make that fail ("permission denied for column pin"). Every other `users` read in `src/` names its columns (`full_name`, `role`, ...), and the `users!fk(full_name)` embeds name theirs. | grep `src/` |
| `LoginForm.jsx:182` treats the password field as a PIN **only when it matches `/^\d{4}$/`**; `pin-login` rejects anything but `^\d{4}$`. | `LoginForm.jsx`, bookX `pin-login` |
| The login form always shows one generic message ("Invalid email or password/PIN"). It sends the anon JWT, so `pin-login` runs with `verify_jwt` on (no `config.toml` entry needed). | `LoginForm.jsx:116-130` |
| Discount approval does not use the PIN (as the brief says). `list_discount_approvers` only checks that an approver HAS a PIN. I add no PIN step there. | `api.js` ~2513 |
| `tenant-isolation.sql:1420` seeds `UPDATE users SET pin = '1234'` to make `list_discount_approvers` return rows. | tests |
| The bookX `pin-login` calls only `login_with_pin` (service role) and then `auth.admin.generateLink`; it never reads `users.pin`. | bookX `index.ts` |
| `local-pull-tenant.sh` NULLs `users.pin` on export; `LOCAL_DEV.md` says `pin-login` is not run locally. | scripts, docs |
| Local DB has 10 users and 0 PINs, so the backfill needs a hand-made fixture to be tested. | local DB |

## 2. Decisions I need from the lead (each has my recommendation)

**D1. Where the hash lives. Recommend: a separate table `public.user_pins`, not new columns on `users`.**
The brief says `users.pin_hash` plus a column REVOKE. Because of the table-level grants above, that means: revoke SELECT/INSERT/UPDATE on `users`
from anon and authenticated, grant an explicit column list, and rewrite `AuthContext` to name its columns. It also breaks silently the next time
anyone adds a column to `users` (the new column is unreadable until someone remembers the grant). A side table avoids all of it:
`user_pins(user_id PK -> users, pin_hash, failed_count, locked_until, updated_at)`, RLS on, no policy, `REVOKE ALL` from PUBLIC/anon/authenticated/service_role
(same pattern as `action_log`). Nothing readable, `AuthContext` untouched, `select('*')` keeps working. `users.pin` stays one release, always NULL.
Cost: a join in three functions. If the lead wants the brief's literal columns, I will do the column-grant version and change `AuthContext`; say so.

**D2. PIN length. Recommend: exactly 4 digits for 022, not 4-6.**
The form only routes a 4-digit value to PIN login, and `pin-login` rejects the rest. A 5-6 digit PIN could never log in, and widening the form regex would send
5-6 digit passwords (the local config sets the minimum password length to 6; prod unverified) to the PIN path. Widening is a client + edge change; make it its own ticket.
Weakness to state plainly: 10,000 combinations. The lock (5 tries / 15 min) makes a blind guess of one account take about 10 days on average, but it does not
make a 4-digit PIN strong. Trivial PINs refused in the set functions: all one digit and ascending/descending runs (1111, 1234, 4321, 0000).

**D3. `admin_reset_pin(p_user)` result. Recommend: generate a random 4-digit temporary PIN, return it once to the admin, store only the hash.**
The brief gives no PIN argument, so either it clears the PIN or it generates one. Clearing leaves a PIN-only staff member with no way to set a new PIN
(`set_my_pin` needs a session). A temporary PIN returned once is normal reset practice and is not stored readable. The audit row (`user.reset_pin`) holds ids only, never the PIN.
The caller must be `admin`, target in the same org, not self. An admin can therefore reset another admin and log in as them; admin is already the top
role and the action is audited, but say so if that is not acceptable (alternative: refuse targets with role `admin`).

**D4. Hash-on-write trigger on `users.pin`. Recommend: include it.**
`BEFORE INSERT OR UPDATE OF pin ON users`: if `NEW.pin` is not NULL, hash it into `user_pins`, set `NEW.pin := NULL`. This keeps working any prod process
that still writes a plain PIN (unknown, CMD-11) and keeps the existing test fixture (`UPDATE users SET pin='1234'`), and it means plain text can never come
back. It does not validate format (same as the backfill). Remove it when the column is dropped.

## 3. Schema (migration 022)

```
CREATE TABLE public.user_pins (
  user_id       uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  pin_hash      text,                       -- bcrypt: extensions.crypt(pin, extensions.gen_salt('bf', 10))
  failed_count  integer NOT NULL DEFAULT 0,
  locked_until  timestamptz,
  updated_at    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.user_pins ENABLE ROW LEVEL SECURITY;           -- no policies
REVOKE ALL ON public.user_pins FROM PUBLIC, anon, authenticated, service_role;
```
Supabase default privileges grant new public tables to anon/authenticated, so the REVOKE is explicit. The owner (postgres) and the SECURITY DEFINER
functions below are the only readers. `pgcrypto` is already installed in schema `extensions`; every call is schema-qualified.

**Backfill, same transaction:** `INSERT INTO user_pins SELECT id, crypt(pin, gen_salt('bf',10)) FROM users WHERE pin IS NOT NULL AND pin <> ''`, then
`UPDATE users SET pin = NULL WHERE pin IS NOT NULL` (empty strings too). No format check: every former PIN keeps working, including weak ones.
`migration-022-preflight.sql` (read-only, counts only, never prints a PIN): users with a PIN; with a non-4-digit PIN (these can never log in through
`pin-login` today either); with a trivial PIN.

## 4. Functions

All `SECURITY DEFINER`, `SET search_path = public, extensions`. Existing functions are `CREATE OR REPLACE` (same signature and return shape), so the 009 grants
survive; `login_with_pin` / `verify_pin` stay EXECUTE for `service_role` only. They must never be dropped and recreated.

**`login_with_pin(email, pin, org_slug)` and `verify_pin(...)`** share one internal helper `_pin_check(email, pin, org_slug)` returning the user row or NULL.
Rules, in order:
1. Look the user up (`is_active`). Not found, no `user_pins` row, or no hash: run `crypt(pin, <constant dummy bcrypt hash>)` and return the generic error. No counter.
2. Lock the `user_pins` row (`FOR UPDATE`, so two parallel guesses cannot both slip under the limit).
3. If `locked_until > now()`: run the dummy `crypt`, return the generic error, change nothing (a locked account is not extended by more guessing).
4. If `locked_until` has passed: reset `failed_count = 0`, `locked_until = NULL`.
5. Wrong PIN **or org slug given and not the user's org**: `failed_count + 1`; on reaching 5 set `locked_until = now() + 15 min`. Return the generic error.
   (Today a wrong org slug after a right PIN returns a different message, which tells a guesser the PIN was right. I make it generic and count it as a failure.)
6. Right PIN: `failed_count = 0`, `locked_until = NULL`, return the same success shape as today.
Wrong email, wrong PIN, locked account and wrong org all return the existing text `Invalid email or PIN`. The function returns (never raises) on failure so the
counter update commits.
Trade-off to accept: anyone who knows an email can lock that account for 15 minutes by guessing wrong. There is no per-IP limit in `pin-login` today (not added here;
note for a later ticket). Locking is not audited (no actor to attribute it to).

**`set_my_pin(p_current_pin text, p_new_pin text) -> jsonb`** (authenticated). Actor = `auth.uid()` with an active `users` row (customers refused), via `_act_resolve(NULL)`.
New PIN: exactly 4 digits, not trivial. If the user has a hash, `p_current_pin` must match it; a wrong one counts toward the same 5-failure lock and returns the same
generic error. If the user has no hash yet, `p_current_pin` may be NULL (first PIN, they are already signed in with a password). Success clears the counter. Audited as
`user.set_pin` (ids only).

**`admin_reset_pin(p_user uuid) -> jsonb`** (authenticated). `_act_resolve(NULL)`; role must be `admin` (not `admin_viewer`, manager, staff, practitioner, service role, agents);
target in the caller's org; target is not the caller. Writes a new random hash, clears the counter and lock, returns `{temporary_pin}` once. Audited as `user.reset_pin`
(actor, target, org; never the PIN) through `_act_finish(ctx, 'user.reset_pin', org, NULL, inputs, true, data, ..., p_user, NULL, 'users')`. The returned `data` that goes into
`action_log.result` must not contain the PIN: I return it in a separate field the log call does not receive (checked by a test that greps `action_log` for the PIN).

**`list_discount_approvers()`**: `u.pin IS NOT NULL AND u.pin <> ''` becomes `EXISTS (SELECT 1 FROM user_pins p WHERE p.user_id = u.id AND p.pin_hash IS NOT NULL)`. Rest of the body
is the 014 version unchanged.

## 5. Callers of `users.pin` / PIN login

| Caller | Change |
|---|---|
| `login_with_pin`, `verify_pin`, `list_discount_approvers` | rewritten as above |
| `supabase/functions/pin-login` | **not in this repo; copy it in** (bookX version, 97 lines). It satisfies the brief's condition: it only calls `login_with_pin`, never reads `users.pin`. Differences from what I'd ship: none needed for 022 (4-digit regex stays, per D2). Observations, not changed: CORS `*`, no IP throttle, esm.sh imports pinned at `supabase-js@2.45.0` / std `0.224.0`. Prod's deployed version is UNVERIFIED; deploy from this repo after 022 is a human step. |
| `LoginForm.jsx` | none |
| `AuthContext.jsx:93` `select('*')` | none under D1 (would need column names under the brief's column approach) |
| `tenant-isolation.sql:1420` | keeps working through the D4 trigger |
| `local-pull-tenant.sh` | none (`users.pin` still NULLed; `user_pins` is not in its table list, so it is not pulled) |
| Any screen that sets a PIN | **none exists in `src/`.** No client change in 022. A "change my PIN" screen is a later ticket (`set_my_pin` is the call it would use). |
| A prod writer of `users.pin` outside this repo | UNVERIFIED. The D4 trigger makes it keep working and keeps it from storing plain text. |

## 6. Rollback (`migration-022-rollback.sql`)

It cannot restore plain PINs; the plain values are gone after the backfill (take a backup first if wanted). It restores the three old function bodies
(comparing `u.pin`) and the old signatures, drops the trigger, the two new functions and `_pin_check`, **keeps `user_pins` and its hashes, and leaves `users.pin` NULL**.
Consequence, stated plainly: after a rollback PIN login and the discount-approver list do not work for anyone until PINs are written back into `users.pin` by hand.
Rolling forward is the safer recovery, because the old state is the vulnerability. Order: revert the edge function first (it needs no change under D2, so nothing to revert), then the SQL.

## 7. Tests (test:rls, on a private clone DB)

Private DB `cmd62_work`, built fresh from `schema.sql`, `rls.sql`, 001-018 and 022 (no 019/020/021), not the shared `postgres` DB.
1. For each of anon, staff, practitioner, manager, admin, admin_viewer: `SELECT` on `user_pins` is denied (own row too); `SELECT pin FROM users` returns NULL for every visible row;
   direct `INSERT/UPDATE/DELETE` on `user_pins` and `UPDATE users SET pin` denied or 0 rows.
2. Right PIN logs in; wrong PIN does not; 5 wrong in a row lock the account even with the right PIN; unlock after the window (time faked with an `UPDATE` as postgres); a success resets the counter;
   the lock is not extended by guesses while locked.
3. Unknown email, wrong PIN, locked, wrong org slug: identical response text and shape. Unknown email still does a bcrypt compare (checked by a timing-independent test: the dummy path is taken; not a timing test).
4. `admin_reset_pin`: admin of the same org only; refused for admin_viewer/manager/staff/practitioner, other org, self, service role, anon. `set_my_pin`: needs the current PIN once a hash exists, rejects trivial/non-4-digit, wrong current PIN counts toward the lock, customers refused.
5. Backfill: fixture rows with PINs (including `0000`, a non-4-digit value, an empty string); after 022 no row has non-NULL `pin`; each former PIN verifies against its hash; the empty string produced no hash.
6. D4 trigger: writing `users.pin` as postgres and as service_role stores a hash and leaves `pin` NULL.
7. `action_log` has `user.reset_pin` rows with ids only; no PIN anywhere in it.
8. anon allow-list unchanged (the new functions are not anon-executable). Existing `test:rls` baseline on 001-018 stays at 0 FAIL. Rollback round trip on the clone.
Also: `npm test` (I will report the Test Files line), `npm run build`, and an edge test of `pin-login` through `supabase functions serve` against the clone (right PIN returns an OTP; 5 wrong locks).

## 6a. Production notes (for the PR)
- 022 after 011-021 as merged. Run `migration-022-preflight.sql` first. A human confirms no prod process reads `users.pin` directly (CMD-11).
- Deploy `pin-login` from this repo after 022. Tell staff nothing changes for them (same 4-digit PIN).
- Existing weak PINs (the preflight counts them) keep working; they are not rejected by the backfill.

## 7a. Not verified (so far)
- Production: the deployed `pin-login` version, the column grants on `users`, whether any clinic logs in with a PIN, and what writes `users.pin`.
- The behaviour of 022 itself (no SQL written yet).
- Whether `crypt(..., gen_salt('bf', 10))` cost is fine on the production host (about 50-100 ms per check expected; not measured).

## 8. Build notes (2026-11-24, after approval; D1-D4 approved as written)
- Files: `supabase/migration-022-staff-pin.sql`, `-preflight.sql`, `-rollback.sql`; section 3i of `supabase/tests/tenant-isolation.sql` (161 checks); `supabase/tests/migration-022-roundtrip.sh`; `supabase/functions/pin-login/index.ts` (byte-identical copy of the bookX file).
- `CREATE TABLE IF NOT EXISTS user_pins`: the rollback keeps the table on purpose, so rolling forward again after a rollback has to work. The round trip proves it.
- Wrong organization slug now counts as a failure even with the right PIN (as agreed). An inactive user and a user with no hash get the same generic answer and cost one bcrypt compare against a dummy hash.
- Admin may reset another admin; never themselves (`INVALID_INPUT`, use `set_my_pin`). The temporary PIN is added to the returned object AFTER `_act_finish` wrote the log row; the five PIN functions contain no `RAISE`; the test greps every `action_log` column for the PIN (quoted value and key names).
- Authenticated users, any role, cannot write `users.pin` (RLS: no UPDATE/INSERT policy). The tests try an UPDATE of a colleague's and of their own row and an INSERT with a `pin`, for every role.
- Not done as written in section 7: the `pin-login` edge test. `supabase functions serve` talks to the API on 55321, which is backed by the shared `postgres` DB, not the private clone, and the brief says not to use the shared DB. The function only calls `login_with_pin` and `generateLink`; `login_with_pin` is tested at SQL level (service_role can call it; anon, authenticated cannot). An end-to-end run needs 022 on the shared DB (or a second stack) and the lead's go-ahead.
