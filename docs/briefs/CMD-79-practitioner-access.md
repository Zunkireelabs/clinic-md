# Brief: Practitioner access level and login-to-practitioner link · CMD-79

**Status:** ready to build, 2026-11-22 · **Phase:** 2–3 (blocks the Practitioner rows of Home and Inbox) · **Lead:** lead session
**Follows:** `docs/SITEMAP.md` §7 (the role table, and "Decided 2026-11-21" points 1–3), `docs/USER-JOURNEYS.md` 3.1–3.2,
`CLAUDE.md` → Database and Tenancy.

## 1. What and why

Today a practitioner (a `dentists` row) has no link to a login (`users`), and `user_role` is `staff | manager | admin |
admin_viewer`. Sadin decided (SITEMAP §7) that **access level and practitioner profile are separate**:
- a new access level, **`practitioner`**: the limited one, with no money, payroll or settings;
- **any** login can be linked to one practitioner profile. Owner + profile, manager + profile and
  practitioner + profile are all valid.

This ticket adds the role value, the link, the database rules and an admin-only function to set them (no screen). The Home and Inbox
screens that use it are separate tickets.

## 2. Where to work

- Make your own worktree from `origin/main`:
  `git worktree add ../clinic-md-CMD-79 -b feature/CMD-79-practitioner-access origin/main`
- **Local Supabase only** (`npm run start:local`, `npm run test:rls`). Never connect to the cloud project. Never
  apply anything to production. Sadin applies the migration to prod himself, **before** the code reaches `main`.

## 3. Migration `supabase/migration-011-practitioner-access.sql` (+ `-rollback.sql`)

The number 011 is claimed for this ticket. `main` has 001–010, and no open PR uses 011. Put "migration 011" in the
ticket description.

1. `ALTER TYPE public.user_role ADD VALUE 'practitioner';`. A new enum value can't be used in the same transaction,
   so put it first, in its own transaction, and say so in a comment.
2. `users.dentist_id uuid NULL`, linked to the profile **in the same org**: add `UNIQUE (id, org_id)` on `dentists`
   and a composite FK `(dentist_id, org_id) → dentists(id, org_id)` with `ON DELETE SET NULL (dentist_id)`. If your
   Postgres version can't do the column-list form, stop and ask. Add a partial unique index so that one profile has at
   most one login: `UNIQUE (dentist_id) WHERE dentist_id IS NOT NULL`.
3. Add the helper `public.get_user_dentist_id()`: `SECURITY DEFINER`, `STABLE`, `SET search_path = public`. It returns
   the caller's `dentist_id`. Follow migration 009: revoke from `PUBLIC` and `anon`, and grant to `authenticated`
   only.
4. **RLS: check before you write.** `rls.sql` and migrations 001–010 hold about 100 policies that use
   `get_user_role()`. **Step 1 (checkpoint):** write a table in your handoff draft: policy · table · what `staff` gets ·
   what you propose for `practitioner`. Use SITEMAP §7 as the rule: practitioner = read what front desk reads for
   their branch (bookings, patients, dentists, treatments, chairs, calendar); **no** payments, payroll, commissions,
   expenses, discounts approval, settings or user management; can write consultations and notes for bookings where
   they are the booked dentist. **Send that table to the lead and wait for approval before writing policies.**
   Don't widen any existing role's access.
5. The rollback moves `practitioner` users back to `staff`, drops the policies or policy changes, the helper, the index,
   the FK, the column and the `dentists` unique constraint. Postgres can't drop an enum value, so the rollback leaves
   it and says so in a comment.

## 4. App changes (smallest possible)

- Role lists: add `practitioner` wherever a route or menu lists the staff roles (`Routes.jsx` `ProtectedRoute`,
  `StaffSidebar.jsx`, `ProfileMenu.jsx` label "Practitioner", `CommandPalette` sources). In each place, treat it like
  `staff` **minus** Money, Payroll, Settings and Reports. Sidebar for today's app: Calendar, Patients (CRM read),
  Consultation. List every file you touch.
- **Linking, with no screen in this ticket:** `main` has no user-management screen; staff accounts are set up by
  hand. Add one function to migration 011: `public.set_user_access(p_user_id uuid, p_role user_role,
  p_dentist_id uuid)`. It is `SECURITY DEFINER`, granted to `authenticated` only, and refuses unless the caller is
  `admin` in the same org as the target user and the dentist (when it isn't null). Until Settings → People and roles
  exists (Phase 3, its own ticket), Sadin calls it. Don't build a UI for it.
- Load `dentist_id` with the profile in `AuthContext`, so later screens can read `profile.dentist_id`.

## 5. Tests

- `supabase/tests/tenant-isolation.sql`: add cases for a practitioner of org A who can't read org B; a practitioner
  who can't read payments or payroll tables; linking a user to another org's dentist is rejected; one dentist can't be
  linked twice; and the helper is not executable by `anon`.
- Vitest: role-to-menu mapping for `practitioner` (no Money, Settings or Reports).

## 6. Acceptance checks (the lead runs these)

1. On a fresh local DB: `schema.sql` → `rls.sql` → 001–010 → 011 applies cleanly. Then `011-rollback` applies
   cleanly, and 011 re-applies cleanly.
2. `npm run test:rls` passes, with the new cases, on local. `npm test` and `npm run build` pass.
3. Signed in on `start:local` as a seeded `practitioner` linked to a dentist: Money, Payroll, Settings and Reports are
   absent from the sidebar, and their URLs redirect. Calendar and Patients load. A Supabase query from the
   browser console for `payments` returns no rows.
4. As `admin`, `set_user_access` links an admin to a dentist profile. They keep every admin screen, and
   `profile.dentist_id` is set after a reload. As `manager` or `staff`, the call is refused. Using another org's user
   or dentist is refused.
5. The diff only touches what §3–5 name, plus `seed.sql` if you add a practitioner to the local seed (say so).
6. The policy table from §3.4 is in the handoff, with the lead's approval noted.

## 7. Not in scope

"My patients" filtering on Home or Inbox (CMD-76 and the Inbox ticket); the Settings → People and roles redesign;
access level per branch; renaming `dentists` (that is the generic-core ticket).

## 8. Handoff

Use the template in `docs/DEV-APPROACH.md`. End it with a **Not verified** list, and say explicitly that the migration
is **not applied to prod**.
