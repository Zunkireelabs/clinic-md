# Brief: Guard the money functions against roles that may not touch money · CMD-83

**Status:** ready to build, 2026-11-22 · **Priority:** HIGH · **Lead:** lead session
**Follows:** `docs/briefs/CMD-79-practitioner-access.md` (the `practitioner` role, SITEMAP §7: no money, payroll or
settings), `CLAUDE.md` → Database (migration 009 grants), principle 14 (tenant-safe).
**Blocks:** giving anyone the `practitioner` role in production (Sadin's rule: not until CMD-83 is Done).

## 1. What and why

CMD-79 (migration 011) added the `practitioner` role and closed the money **tables** to it through RLS. But
`SECURITY DEFINER` functions skip RLS. The lead's inventory on the local DB (2026-11-22, with 011–013 applied) found:

- **Already safe:** every money function that checks the role uses an allow-list (`NOT IN ('staff','manager','admin')`
  or narrower), so a new role is shut out: `claim_voucher`, `enroll_member`, `extend_membership`, `issue_package`,
  `issue_voucher`, `record_membership_transaction`, `redeem_package_session`, `renew_membership`,
  `resolve_customer_referral_reward`, `update_org_payment_methods`.
- **Already safe:** the `platform_*` functions are gated to platform admins. The trigger and internal functions
  (`sync_booking_payment_status`, `trg_sync_payment_status_on_price`, `update_booking_payment_status`,
  `membership_recompute`, `set_membership_number`, `platform_org_*`) are not executable by `authenticated`.
- **The gap:** these are executable by `authenticated` and check **only the org**, so a `practitioner` (and an
  `admin_viewer`, who should be read-only) can run them:
  `record_membership_payment`, `record_voucher_wallet_payment`, `record_voucher_wallet_payment_pooled`,
  `record_referral_wallet_payment`, `redeem_referral_voucher`, `record_customer_referral` (3 overloads),
  `credit_pending_referral_for_booking`, `get_referral_credit_balance`, `list_membership_status_for_org`,
  `list_vouchers_for_customer`, `search_vouchers_for_payment`, `list_discount_approvers`.

The lead's search went **by name and by the tables a function reads**, so it can miss report or dashboard functions
that return revenue, prices, payroll or commission under other names. Your first job is the full sweep (§3.1).

## 2. Where to work

- Your own worktree, branched from the CMD-88 branch so the sweep covers every function from 011–013:
  `git worktree add ../clinic-md-CMD-83 -b feature/CMD-83-money-definer-guard origin/feature/CMD-88-communication-hub`
- **Migration 014** is claimed for this ticket (011 = PR #15, 012 = PR #16, 013 = PR #17). The PR will target
  `feature/CMD-88-communication-hub` (PR #17), not `main`.
- **Local Supabase only** (clinicmd-local, ports 55321–55323; `npm run test:rls`). Never connect to the cloud project.
  Apply migrations by hand with psql (`scripts/local-db-bootstrap.sh` is buggy, CMD-85).

## 3. What to build

1. **Sweep (checkpoint: send it to the lead and wait for approval before writing SQL).** List **every** `public`
   function that is `SECURITY DEFINER` **and** executable by `authenticated` (query `pg_proc` +
   `has_function_privilege`, don't grep). For each, give one row:
   function · reads or writes money? (payments, prices, payroll, commissions, expenses, wallets, vouchers, memberships,
   packages, discounts, revenue or report totals) · current role check (quote it) · can `practitioner` run it today? ·
   can `admin_viewer` write through it today? · proposed change.
   Functions that touch no money: one line per group is enough (e.g. "act_* / hub_*: guarded by `_act_resolve` +
   `_hub_scope`, no money").
2. **Two helpers** (in 014, `STABLE`, `SECURITY DEFINER`, `SET search_path = public`; revoke from `PUBLIC`
   and `anon`, grant to `authenticated`, as in 009):
   - `public.can_read_money()`: true for `staff`, `manager`, `admin`, `admin_viewer`;
   - `public.can_write_money()`: true for `staff`, `manager`, `admin`.
   These are allow-lists: an unknown or future role gets `false`.
3. **Guard each function in the gap** (the list in §1 plus whatever the sweep adds and the lead approves):
   read functions refuse unless `can_read_money()`; write functions refuse unless `can_write_money()`. Refuse the same
   way the function already fails (same exception or return shape), so the existing UI behaves the same. Change
   nothing else in the body: copy the current definition from the local DB (`pg_get_functiondef`), add the guard,
   and keep the signature, grants and owner.
4. **Don't widen anything.** An allow-list that is already narrower (e.g. `NOT IN ('manager','admin')`) stays as it is.
5. **Rollback** (`migration-014-rollback.sql`): restores each function's exact previous definition and drops the two
   helpers. Generate the "previous" bodies from the local DB, not by hand.

## 4. Tests

- `supabase/tests/tenant-isolation.sql`, new cases:
  - as `practitioner` (seeded practitioner@, linked to a dentist): every guarded function is refused;
  - as `admin_viewer`: every guarded **write** function is refused; read functions still work;
  - as `staff`: one read and one write from the list still work (no regression);
  - `can_read_money` and `can_write_money` are not executable by `anon`;
  - a role-coverage check: no `SECURITY DEFINER` function executable by `authenticated` whose body reads a money table
    lacks either an allow-list role check or a `can_*_money()` call. Name the exceptions explicitly in the test.
- Vitest: nothing new is expected unless you touch app code (you shouldn't).

## 5. Acceptance checks (the lead runs these)

1. On the local DB with 011–013: 014 applies cleanly, the rollback applies cleanly and returns every function to its
   previous definition (compare `pg_get_functiondef` before and after with diff), and 014 re-applies cleanly.
2. `npm run test:rls` passes with the new cases. `npm test` and `npm run build` pass.
3. Through PostgREST with a real login (not psql role switching): as practitioner@, `record_membership_payment` and
   `list_membership_status_for_org` are refused. As staff@ they still work. As an `admin_viewer` (create one locally if
   the seed has none, and say so), a write is refused and a read works.
4. Signed in as staff@ on `start:local` in the browser (agent-browser, saved login `clinicmd-staff`): a membership
   payment and a voucher wallet payment still go through.
5. The sweep table from §3.1 is in the handoff, with the lead's approval noted.
6. The diff touches only migration 014 + its rollback, the tests, and (if needed) `supabase/LOCAL_DEV.md`.

## 6. Not in scope

- Hiding payment UI from practitioners (CMD-84).
- `is_my_booking_row` returning NULL (CMD-87).
- Changing what `staff` may do with money.
- `public_*` anon functions (CMD-44 covers `public_search_booking` and `public_get_booking_by_id`). If the sweep finds
  an anon-executable money function, list it in the handoff; don't fix it here.

## 7. Handoff

Use the template in `docs/DEV-APPROACH.md`. End it with a **Not verified** list, and say explicitly that 014 is
**not applied to prod** and needs 011, 012 and 013 applied first.
