# Local development (OrbStack)

A full local Supabase stack (Postgres, Auth, PostgREST, Realtime, Storage, Studio) in Docker under
[OrbStack](https://orbstack.dev), isolated from the cloud project `aixdpmglcanvuscorylw`
(which currently serves both dev and production). Nothing here talks to the cloud.

## Ports (project_id `clinicmd-local`)

Shifted +1000 from Supabase defaults so this stack runs alongside bookX / other local stacks:

| Service | Port |
|---|---|
| API (PostgREST/Auth/Storage) | 55321 |
| Postgres | 55322 |
| Shadow DB | 55320 |
| Studio | 55323 |
| Mailpit (auth emails) | 55324 |
| Analytics | 55327 |
| Pooler (disabled) | 55329 |
| Edge runtime inspector | 9083 |

## Day-to-day

```bash
open -a OrbStack                    # if not running
supabase start                      # bring up the stack
./scripts/local-db-bootstrap.sh     # schema.sql -> rls.sql -> local-only supplements -> seed.sql -> migration-NNN-*.sql -> test users
npm run start:local                 # app on http://localhost:4029 against the LOCAL db
supabase stop                       # shut down
```

Reset and reseed: `supabase db reset && ./scripts/local-db-bootstrap.sh`.
`./scripts/local-db-bootstrap.sh --dry-run` prints the plan without touching the database; `--help` lists the options.
CI runs `npm run test:rls` on every PR to `main` (job `rls`, `ci.yml`): it starts the DB, runs `./scripts/local-db-bootstrap.sh --no-users`, then the test.
`supabase status` reprints URLs/keys.

## Env switching

- `.env` is the default env and points at the **cloud** project. `.env.cloud` is a gitignored backup of it.
- `.env.localdb` (gitignored; template `.env.localdb.example`) points at the local API with the public
  local demo anon key.
- `npm run start:local` runs Vite with `--mode localdb --port 4029`: it layers `.env.localdb` over `.env`,
  so the running cloud-backed dev server on :4028 is untouched and both can run together.
- To switch the default instead: `cp .env.localdb .env` and restart (`cp .env.cloud .env` to go back).
- Why not `.env.local`? Vite auto-loads `.env.local` over `.env` and restarts the dev server when it
  changes, which would silently flip a running cloud-backed app to the local DB.

## Test users

`scripts/local-create-test-users.sh` (run by the bootstrap) creates `admin@`, `manager@` and `staff@clinicmd.test`
for org `bright-smile-dental`, branch Kathmandu Main (GoTrue user + `public.users` + `user_branches`).
Passwords are generated into `supabase/LOCAL_TEST_USERS.md` (gitignored, mode 600) and reused on re-runs. They are never
printed and never put on a command line; don't `cat` that file into a terminal or log you share.

```bash
./scripts/local-create-test-users.sh                  # the stack `supabase status` reports for this repo
./scripts/local-create-test-users.sh --dry-run        # hosts, emails, roles, new vs reused password; sends and writes nothing
./scripts/local-create-test-users.sh --workdir DIR    # another LOCAL stack; its passwords go to DIR/supabase/LOCAL_TEST_USERS.md
```

It runs `supabase status` in the repo (or `--workdir`), never in your current directory, and refuses to send anything
unless both the DB URL and the API URL have the host `127.0.0.1` or `localhost`. That check is shared with the
bootstrap in `scripts/lib/local-db-url.sh` (parsed host, one host only, no `host=`/`hostaddr=`/`service=` in the
query, PG* variables cleared).

Worktrees share the one local stack, so the script always uses the **main checkout's** `supabase/LOCAL_TEST_USERS.md`
(it prints which file) and reuses those passwords; it refuses, changing nothing, if that file is missing. Never copy the
file into a worktree. If a worktree runs its own separate stack, pass `--workdir <dir>` (to the script or the bootstrap):
it then uses `<dir>/supabase/LOCAL_TEST_USERS.md` and that dir's `supabase status`.

## Busy calendar seed

`./scripts/local-seed-busy-calendar.sh` fills Bright Smile / Kathmandu Main with a realistic busy week, from
yesterday through +6 days (today busiest). It adds 3 extra dentists, double-bookings, "+N" clusters, stacked Unassigned
bookings, shared two-dentist bookings, patient alerts, payments and prior dues. Re-running re-seeds;
`--clean` removes it. Everything is tagged (`@busy.seed.test` emails, fixed-id seed dentists), so other data is
untouched. Fictional data only.

## Why a bootstrap script

Schema/RLS/seed live in raw `supabase/*.sql`, not the CLI's `supabase/migrations/` convention, so
`scripts/local-db-bootstrap.sh` replays them with `psql`. `[db.seed]` is disabled in `config.toml` so the CLI doesn't
auto-seed an empty DB. Order is `schema.sql`, `rls.sql`, `scripts/local-only-supplemental-*.sql` (none yet), `seed.sql`,
then every `supabase/migration-NNN-*.sql` present, in numeric order (so a stacked branch's 011+ files are picked up too).

What the script guarantees (CMD-85):

- **Local only.** The DB URL comes from `--db-url` or, without it, from `supabase status` run in the repo. Nothing else:
  no `.env*` file is read and nothing falls back to another URL. The URL's host must be exactly `127.0.0.1` or
  `localhost` (parsed, not a substring match); a query that sets `host`, `hostaddr` or `service` is refused and the
  `PG*` connection variables are cleared. A refusal prints the host only, never the password.
- **Forward files only.** `-rollback.sql` and `-preflight.sql` files are never applied (before CMD-85 the script applied
  them right after their forward file, which undid 007, 009 and 010 and ran 008's rollback first). Two forward files with
  the same number stop the script.
- **Stops at the first error**, naming the file and listing what was applied before it (`ON_ERROR_STOP=1`, `psql -X`).
  A file without its own `BEGIN`/`COMMIT` runs as one transaction; the numbered migrations manage their own.
- **Refuses a database that already has the schema** for a full run: `supabase db reset` first, or step with `--from`.
- Prints the files applied and the time taken.

Stepping through migrations (for QC or rehearsals; the DB must already have everything before `--from`):

```bash
./scripts/local-db-bootstrap.sh --to 0                 # schema, RLS and seed only
./scripts/local-db-bootstrap.sh --to 10                # ... plus migrations 001-010
./scripts/local-db-bootstrap.sh --from 11 --to 16      # then only 011-016
./scripts/local-db-bootstrap.sh --dry-run --from 17    # show what --from 17 would apply
```

Test users are created only by a full run against the stack from `supabase status` (not with `--from`, `--db-url`
or `--no-users`). For another stack, run `scripts/local-create-test-users.sh --workdir <that stack's folder>` after it.

## Known gaps

- Fresh replay of schema/rls/seed needed **no fixes**; no supplemental SQL exists yet.
- `pg_cron` (1.6.4) and `pg_net` are available and preloaded but **not enabled** by default; migrations that
  need them should `CREATE EXTENSION IF NOT EXISTS pg_cron;` (verified locally: enable + `cron.schedule` work).
- The `pin-login` Edge Function (if used in cloud) is not available locally; email/password login works.
- `config.toml` sets `api.auto_expose_new_tables = true` (deprecated by the CLI, removal 2026-10-30) so
  local grants match the cloud's older default; revisit when the CLI drops it.
- Local data is the seed only (1 org, 1 branch, 3 dentists, 10 bookings); there is no cloud data copy.

## Migrations (blocks, transfers, ...)

New DB changes live in `supabase/migration-NNN-*.sql` (numbered from 001; `schema.sql`/`rls.sql` stay as production snapshots).
Each is idempotent (`IF NOT EXISTS`, `CREATE OR REPLACE`, `DROP POLICY IF EXISTS`) because it will later be applied by hand to
production — only with the owner's explicit approval. The bootstrap replays them in numeric order. So far:

- `migration-001-manual-blocks.sql` — `manual_blocks` + `manual_block_exceptions` tables, indexes, org-isolated RLS, grants.
- `migration-002-manual-blocks-public-availability.sql` — merges blocks into `public_check_branch_bookings_range` (same signature/columns).

The app tolerates a database without these tables (the calendar just shows no blocks), so the cloud-backed app keeps working
until they are promoted; "Add block" will fail there until then.

## Pulling a real tenant from the cloud (read-only)

`./scripts/local-pull-tenant.sh "<org name or slug>"` (e.g. `"Dental City"`) copies ONE tenant from the cloud project into
the local stack and creates `admin@<slug>.test` / `manager@<slug>.test` logins (passwords appended to the gitignored
`supabase/LOCAL_TEST_USERS.md`; log in at `/<slug>/login` on the local app).

- **Cloud is production, read-only.** The URL comes from the gitignored `.env.clouddb` (`CLOUD_DB_URL=...`, mode 600) and is never
  printed. Every cloud statement runs in `BEGIN READ ONLY ... ROLLBACK` (the URL may be a pooler that ignores `PGOPTIONS`, so the
  guard is per transaction); only `SELECT` / `\copy (SELECT ...) TO` is used. No migrations, no `link`, no writes.
- **One org only.** Exactly one org must match, every query is filtered by org / its branches / parent keys, and the script aborts
  if any exported `org_id` differs.
- **No auth data.** `auth.users`, identities, passwords and sessions are not copied. Each tenant `public.users` row gets a local
  `auth.users` stub (same id, `<id>@<slug>.local`, no password).
- **Skipped / nulled:** `customer_accounts`, `outreach_provider_config`, `platform_admins`, `schema_migrations` skipped;
  `users.pin`, `org_commission_*.created_by`, `bookings.customer_account_id` nulled.
- **Schema drift** is handled by exporting the intersection of cloud and local columns (excluding generated ones); drift is reported.
- **PII:** exports go to a private `mktemp` dir that is deleted on exit (success or failure). Never commit tenant data.
- **Idempotent:** the org's local rows are deleted first, then reloaded (replica mode: FK checks and side-effect triggers are off during
  the load; an FK-orphan check runs afterwards). Local `booking_number` collisions with the demo org get a `-L` suffix on the *demo* row.
