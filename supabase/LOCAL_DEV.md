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
./scripts/local-db-bootstrap.sh     # schema.sql -> rls.sql -> local-only supplements -> seed.sql -> migration-*.sql -> test users
npm run start:local                 # app on http://localhost:4029 against the LOCAL db
supabase stop                       # shut down
```

Reset and reseed: `supabase db reset && ./scripts/local-db-bootstrap.sh`.
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
Passwords are generated into `supabase/LOCAL_TEST_USERS.md` (gitignored) and reused on re-runs.

## Why a bootstrap script

Schema/RLS/seed live in raw `supabase/*.sql`, not the CLI's `supabase/migrations/` convention, so
`scripts/local-db-bootstrap.sh` replays them with `psql` (each file in one transaction). `[db.seed]` is
disabled in `config.toml` so the CLI doesn't auto-seed an empty DB. Order is `schema.sql`, `rls.sql`,
`scripts/local-only-supplemental-*.sql` (none yet), `seed.sql`, then `supabase/migration-NN-*.sql` in numeric order.

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
