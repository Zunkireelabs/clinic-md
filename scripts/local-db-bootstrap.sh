#!/usr/bin/env bash
# Bootstraps the LOCAL OrbStack-hosted Supabase Postgres (started via `supabase start`) with
# this repo's schema, RLS policies, seed data and any migration-*.sql files.
#
# This never touches the cloud project — it refuses to run unless the DB URL is local.
#
# Usage:
#   supabase start                    # once, to bring up the local stack
#   ./scripts/local-db-bootstrap.sh   # apply schema + rls + seed + migrations
#
# To wipe and start over:
#   supabase db reset && ./scripts/local-db-bootstrap.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPABASE_DIR="$REPO_ROOT/supabase"

DB_URL="$(supabase status -o env 2>/dev/null | grep '^DB_URL=' | cut -d= -f2- | tr -d '"')"
if [ -z "$DB_URL" ]; then
  echo "Could not read DB_URL from 'supabase status' — is the local stack running? Try 'supabase start' first." >&2
  exit 1
fi

case "$DB_URL" in
  *127.0.0.1*|*localhost*) ;;
  *)
    echo "Refusing to run: DB_URL does not look local (${DB_URL})." >&2
    exit 1
    ;;
esac

run_sql() {
  local file="$1"
  echo "==> Applying $(basename "$file")"
  # -1 wraps each file in one transaction so a failure leaves nothing half-applied.
  psql "$DB_URL" -v ON_ERROR_STOP=1 -1 -f "$file"
}

run_sql "$SUPABASE_DIR/schema.sql"
run_sql "$SUPABASE_DIR/rls.sql"

# Local-only gap fillers (see supabase/LOCAL_DEV.md "Known gaps"), applied in name order.
for f in $(ls "$REPO_ROOT"/scripts/local-only-supplemental-*.sql 2>/dev/null | sort); do
  run_sql "$f"
done

run_sql "$SUPABASE_DIR/seed.sql"

# Future migrations (blocks, transfers, ...) replay in numeric order after the seed.
for f in $(ls "$SUPABASE_DIR"/migration-[0-9]*.sql 2>/dev/null | sort -V); do
  run_sql "$f"
done

# Local test users (auth.users + app linkage). Passwords are generated into a gitignored file.
if [ -x "$REPO_ROOT/scripts/local-create-test-users.sh" ]; then
  "$REPO_ROOT/scripts/local-create-test-users.sh"
fi

echo "Local DB bootstrap complete. Studio: http://127.0.0.1:55323"
