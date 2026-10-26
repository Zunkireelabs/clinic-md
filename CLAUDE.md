# ClinicMD — Claude Code Guide

ClinicMD is a **dental clinic booking and management SPA** (Zunkireelabs). Forked from the
book-spa / Zennly codebase on 2026-09-13 and adapted: therapist → dentist, room → chair,
service → treatment. Repo: `Zunkireelabs/clinic-md`. Production: `app.clinicmd.pro`.

> This file was written 2026-10-25 from `origin/main @ 01f5296`. Where something could not be
> verified from git it is marked **UNVERIFIED** — do not state those as fact.
> Branch `feat/calendar-zennly-parity` and local `main` are far behind `origin/main`; read the
> code from `origin/main` (e.g. `git show origin/main:path`) or branch from it before working.

## Work tracking — Plane is the single source of truth

All development work is tracked in **Plane**: project **ClinicMD**, key `CMD`, workspace
`zunkireelabs`, via the `plane` MCP server (project id `026ab12b-6657-487f-8437-41d53f057a93`).
Full rules: `.claude/skills/project-pm/SKILL.md` ("PLANE WORKFLOW"), ids and queries in
`.claude/skills/project-pm/plane.md`, and the company SOP (`zunkireelabs-org/SOPs/developer-workflow`, OPS-1).
If the `plane` tools are missing, run `/mcp` → plane → authenticate.

- No work without a ticket. Search Plane first; create one (with a parent epic) if none exists.
- Ticket id goes in the branch name and PR title: `feature/CMD-123-short-name`, `CMD-123: ...`.
- Move the ticket as the work moves:
  `Backlog → Todo → In Progress → In Review (PR open) → On Stage (merged to stage) → Done (live on main)`.
  There is no `stage` branch yet (CMD-18): until it exists, skip On Stage and set Done only once the Deploy
  workflow run for the merge to `main` has succeeded.
- Done means live in production, not merged.
- Anything you can't verify gets the `needs-verification` label; never state it as fact.

**HARD RULE — every developer, every session (human or Claude), no exceptions:**
1. **Your work is in Plane before you start it.** Every fix, feature, migration, data fix, hotfix, investigation
   or follow-up has a `CMD` ticket with an assignee. Untracked work is not allowed, however small.
2. **One ticket per piece of work — no duplicates.** Search Plane before creating. If someone else's ticket
   already covers it, comment on that ticket or link a child; never open a second one.
3. **`tasks/TRACKER.md` is the one to-do file in this repo**, for the whole team. It is **generated from Plane**
   by `/project-pm sync`. **Never hand-edit it, and never push its content back into Plane.** A git conflict in
   it → take either side and re-run sync. **Use `/project-pm` for all of this:** "status", "what's mine?",
   "start CMD-n", "sync".
4. **No other to-do lists.** Not in `todo.md`, handoffs, briefs, PR descriptions or session logs.
5. **Claim your migration number in Plane** (in the ticket description) after checking `supabase/` on `main`
   and open PRs. Two PRs must never use the same number.
6. **Keep the state honest** as the work moves. A PR without a `CMD` id in its title doesn't get merged.

## Branching and deploy — current reality vs target

- **Today:** `feature/*` → PR → `main`. `main` **auto-deploys to production** on every push
  (`.github/workflows/deploy.yml`). There is **no `stage` branch and no staging environment**.
  CI (`ci.yml`) runs `npm test` + `npm run build` on PRs to `main`. The deploy workflow's own
  pre-deploy job runs **only `npm run build`** (no tests), and whether GitHub branch protection
  forces PRs/CI on `main` is **UNVERIFIED** (CMD-42, CMD-43).
- **Target:** `feature/* → stage → main`, matching Zennly. Tracked in Plane ("Add a staging
  environment + stage branch"). Until it exists, a merge to `main` goes straight to prod, so
  treat every PR to `main` as a production release: review carefully, and never merge a
  migration-dependent change before its migration is applied (see Database).
- The README is stale: it lists FullCalendar and Framer Motion (not dependencies), a `stage`
  branch/staging Supabase project (neither exists) and omits `start:local`/`test:rls` (CMD-17).
- Deploy: build → push `ghcr.io/zunkireelabs/book-dental:prod` (+ `prod-<sha>`) → SSH to the
  VPS (`devprojects/clinicmd`), `docker compose up -d`, health check. `rollback.yml` redeploys a
  previous `prod-<sha>` image. The image/container still use the old `book-dental` name.
- Deploy script on the VPS does `git reset --hard origin/main` + `git clean -fd` — nothing
  uncommitted should live in that directory.

## Stack

React 18 + Vite 5 (**JSX, not TypeScript**), Tailwind CSS 3, React Router 6 (Context API, no
Redux), Supabase (Postgres, Auth, RLS, Realtime, Edge Functions), PostHog, Vitest.

```bash
npm install
npm start            # vite dev server, port 4028
npm run start:local  # vite --mode localdb --port 4029  (local Supabase; see supabase/LOCAL_DEV.md)
npm test             # vitest run
npm run test:rls     # psql tenant-isolation test against LOCAL Supabase (127.0.0.1:55322 by default)
npm run build        # production build -> build/
```

**Prefer `npm run start:local`.** `.env.example` says its single Supabase project "serves both
local dev and production for now", so a plain `npm start` on a copy of it may touch production
data (UNVERIFIED which project it is; CMD-41). Never run `test:rls` against a non-local DB.

Never put a `service_role` key in any env file or client code — only Supabase `anon` keys.
**Do not read `.env*` files** (`.env`, `.env.cloud`, `.env.clouddb`, `.env.localdb`); work from
`.env.example`. Never paste secret values into code, commits, PRs or Plane tickets.

## Tenancy and roles

Multi-tenant by organization, then branch (clinic): routes live under `/:orgSlug/...`.
Staff roles: `staff`, `manager`, `admin`, `admin_viewer`. Patients (customers) authenticate
per tenant. A platform super-admin area (`/platform/*`) sits behind
`VITE_ENABLE_PLATFORM_ADMIN`. Every table and query must be tenant-scoped; RLS is the safety net,
not a substitute for scoping in the query.

## Code map (`src/`)

`pages/` — branch-manager-dashboard (CRM, Payroll, Performance, Reports, Settings, Packages,
Memberships, Vouchers, Outreach, Referrals, Outstanding, Governance, MasterData, and the
operational **calendar** at `components/calendar/`: 4-Day/Day/Unassigned, blocks, staff
transfers; there is no `pages/calendar`, and `attendance-calendar` only redirects) ·
branch-staff-dashboard · booking-management-portal · booking-details-assignment-modal ·
consultation (AI) · patient-chart · customer-booking-flow-v2 (routes use only v2, but **v2
imports six components from the v1 `customer-booking-flow/` folder — do not delete it**, CMD-24)
· customer login/signup/account · org-finder · platform. Navigation is driven by a nav registry
(module-based sidebar). `contexts/` — Auth → Org → Branch → AIAssistant (+ Tenant for patient
routes). `lib/featureFlags.js` — build-time flags.

## Database (hand-applied — be careful)

- `supabase/` has **no migrations directory and no runner**: a consolidated `schema.sql`,
  `rls.sql`, `seed.sql`, plus numbered `supabase/migration-NNN-*.sql` files (001–010; only
  007–010 have `-rollback.sql`, 007 also has a read-only `-preflight.sql`). They are **applied by
  hand** (psql). Which are applied in prod is **UNVERIFIED** (CMD-11 — including 001–005).
- Before adding a migration: take the next free number (check Plane and `supabase/`), write a
  rollback file, state in the ticket whether it is applied to prod, and **apply it to prod
  before the code that needs it reaches `main`** — `main` deploys immediately.
- Security-sensitive functions are `SECURITY DEFINER`. Migration 009 revokes anon/PUBLIC EXECUTE
  on all of them and re-grants anon only on a 10-name allow-list (the `public_*` booking-flow
  functions, `find_customer_for_booking`, `upsert_customer_for_booking`). That list still
  includes `public_search_booking` and `public_get_booking_by_id` (exact-match, but full
  booking rows; CMD-44). Do not add anon-executable functions that return other tenants' data.
- `supabase/tests/tenant-isolation.sql` (`npm run test:rls`, local DB only) is **not run in CI**
  (CMD-20).
- Edge functions: `consultation-analyze-image`, `consultation-push`, `consultation-summarize`,
  `consultation-transcribe`, `phone-pair`, `send-message` (under `supabase/functions/`).

## Feature flags (build-time, baked into the image)

`MEMBERSHIP_ENABLED`, `VOUCHER_ENABLED`, `CUSTOMER_REFERRALS_ENABLED`, `OUTREACH_ENABLED`,
`PLATFORM_ADMIN_ENABLED`, `CONSULTATION_ENABLED` (`VITE_ENABLE_*`). Changing one needs a rebuild.
**Known inconsistency:** `deploy.yml` builds prod with membership and vouchers `true`, while
`featureFlags.js` says their migrations were deliberately not applied in prod — one of those is
wrong (CMD-13). `deploy.yml` sets referrals `false` and does not pass outreach/platform-admin
(off). `VITE_ENABLE_CONSULTATION` comes from GitHub `vars`: **UNVERIFIED** (CMD-12).
`schema.sql` **does** define the membership, voucher, referral, outreach and platform tables, but
the numbered migration files the flag comments cite (071, 078, 102–117, from the bookX lineage)
**are not in this repo**, so nothing records how prod got (or did not get) those tables. The
comments in `featureFlags.js` ("ON in staging", `docker-compose.dev.yml`) are stale.

## Rules for Claude sessions

1. Plane first (see above). Move the ticket's state as the work moves.
2. Read before writing; keep changes minimal and tenant-safe. Match surrounding code style.
3. Run `npm test` and `npm run build` before opening a PR. Do not claim "done" without them.
4. PRs target `main` for now (`stage` once it exists); title `CMD-123: ...`; body links the ticket.
5. Never force-push `main`, never merge your own PR to `main` without Sadin's go-ahead (it
   deploys to production), never run commands against the production database or VPS from
   here — hand those to a human or the Infrastructure/Deployment operators.
6. Do not rename the `book-dental` image/containers as a drive-by — it touches the workflows,
   the VPS compose file and GHCR (a Plane ticket covers it).
7. Record decisions and blockers as ticket comments, not just in chat.
