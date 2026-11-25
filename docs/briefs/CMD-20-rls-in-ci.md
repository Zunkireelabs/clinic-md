# Brief: Run the tenant-isolation test in CI · CMD-20 · no migration

Lead session, 2026-11-25. Groundwork (CI only). Builder A (clinic-md-e2). Parent epic CMD-5 (Security & Tenant Isolation).

## Why
`supabase/tests/tenant-isolation.sql` (`npm run test:rls`) checks that no clinic can see or change another clinic's rows. Today it runs
only when someone remembers, on a local DB. `ci.yml` runs `npm test` and `npm run build` only. A cross-clinic leak can reach `main`,
and `main` deploys to production.

## Where
New worktree `~/Projects/clinic-md-CMD-20`, branch `feature/CMD-20-rls-in-ci` from **`origin/main`** (not the PR stack). PR to `main`,
title `CMD-20: run the tenant-isolation test in CI`. Copy `~/Projects/clinic-md/.claude/settings.local.json` into the new worktree's
`.claude/` first (ponytail; merge it into an existing settings.local.json rather than overwriting).

## Facts you need (checked by the lead on origin/main)
- `test:rls` is `psql "${RLS_DB_URL:-…127.0.0.1:55322…}" … | grep -E '^(FAIL|SUMMARY|COVERAGE)'; exit ${PIPESTATUS[0]}`.
  **`PIPESTATUS` is bash-only.** npm runs scripts with `/bin/sh`, which is bash on macOS but **dash on ubuntu-latest**, where
  `${PIPESTATUS[0]}` is a "Bad substitution" error. So in CI the script would fail every time, or report the wrong status. Prove the
  behaviour first (run it under `dash` locally or in the runner), then fix it so the exit code is psql's under both shells without losing the grep filter.
- The test file inserts into `auth.users` and switches to the `anon` / `authenticated` roles, so it needs a **Supabase Postgres**
  (the `supabase/postgres` image with Supabase's roles and `auth` schema). Plain `postgres:16` won't do.
- `scripts/local-db-bootstrap.sh` is the one place that knows the apply order: schema.sql → rls.sql → local-only supplements → seed.sql →
  migration-*.sql (`sort -V`) → test users. Test users need GoTrue (the full stack) and are **not** needed by the test.
- `supabase/config.toml`: project `clinicmd-local`, DB port 55322.

## Build
1. A new `rls` job in `.github/workflows/ci.yml` (same trigger: PRs to `main`), beside the existing `build` job:
   install the Supabase CLI (`supabase/setup-cli`, pinned version), start **only what the test needs** (try `supabase db start` first;
   fall back to `supabase start` with the unneeded services excluded `-x …` only if `db start` is missing the `auth` schema or roles),
   apply the database with the bootstrap's order, run `npm run test:rls`.
2. **One source for the apply order.** Do not copy the file list into the workflow. Give `local-db-bootstrap.sh` a way to skip the test
   users (e.g. `--no-test-users` or an env var) and call it from CI. Local behaviour with no flag stays exactly as today.
3. Fix the `test:rls` exit code (above).
4. Update `supabase/LOCAL_DEV.md` (a line: CI runs it on every PR to main) and the "Tenant-isolation test is not in CI (CMD-20)" line in
   `docs/DEV-APPROACH.md`. Do not edit CLAUDE.md; the lead does that.

## Must not
- No secrets in the new job, and no cloud URL anywhere in it. The DB URL is 127.0.0.1. The job must not be able to reach the prod project.
- Don't touch `deploy.yml`, branch protection (CMD-42) or the test SQL itself. If the test FAILs on `main` today, stop and report;
  don't "fix" the test.

## Acceptance checks (the lead re-runs these)
1. The PR's `rls` job is green on the PR, and the log shows the `SUMMARY` line and 0 FAIL.
2. **It really gates:** one throwaway commit on the branch that adds `CREATE POLICY … USING (true)` on an org table in a new
   `migration-999-ci-probe.sql` makes the `rls` job red with a FAIL line. Then revert it, and the job goes green again. Link both run URLs in the handoff.
   The probe must not stay in the branch history that's handed in (revert or drop it; say which).
3. `test:rls` returns non-zero on a FAIL and zero on a pass, under both `bash` and `dash` (show both runs locally).
4. `./scripts/local-db-bootstrap.sh` with no flag still creates the test users locally. With the new flag it skips them.
5. The new job adds 5 minutes or less to CI. Report the measured time.
6. `npm test` and `npm run build` pass.
7. The job uses no `secrets.*` (grep the diff).

## Handoff
The branch, PR link, both run URLs, the measured time, and a **Not verified** list.
