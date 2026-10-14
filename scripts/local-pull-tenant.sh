#!/usr/bin/env bash
# Copies ONE tenant (organization) from the CLOUD database into the LOCAL Supabase stack, read-only on the
# cloud side, and creates local-only admin/manager logins for it.
#
# Usage:  ./scripts/local-pull-tenant.sh "<org name or slug>"      (e.g. "Dental City")
#
# SAFETY
#  * The cloud is PRODUCTION and is only ever read. Every cloud statement runs inside
#    BEGIN READ ONLY ... ROLLBACK (enforced per transaction because the URL may point at a pooler that ignores
#    PGOPTIONS), and only SELECT / \copy (SELECT ...) TO is issued.
#  * The cloud URL comes from .env.clouddb (gitignored). It is never printed, logged or written elsewhere;
#    cloud stderr is passed through a redaction filter.
#  * Only the one org's rows are exported (every query is filtered by org_id / the org's branches / parent keys).
#  * No auth data: auth.users, identities, passwords and sessions are NOT copied. Local auth.users STUBS
#    (id = the real public.users id, non-routable email, no password) are created so foreign keys hold.
#  * Secret-ish columns are nulled/skipped (see SKIPPED below). Exports contain real PII, so they live in a
#    private mktemp dir that is deleted on exit (success or failure).
#  * Local writes only, and only after the local-URL guard passes. Idempotent: the org's local rows are
#    deleted first, then reloaded.
#
# SKIPPED: customer_accounts (customer-portal logins linked to auth.users), outreach_provider_config
#   (provider settings may hold credentials), platform_admins, schema_migrations; column users.pin (staff PIN) is
#   nulled; created_by on org_commission_* (references auth.users) and bookings.customer_account_id are nulled.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
ORG_QUERY="${1:-}"
[ -n "$ORG_QUERY" ] || { echo "Usage: $0 \"<org name or slug>\"" >&2; exit 1; }

# ── local target guard (same pattern as local-db-bootstrap.sh) ─────────────────────────────────
STATUS="$(supabase status -o env 2>/dev/null)"
LOCAL_DB="$(echo "$STATUS" | grep '^DB_URL=' | cut -d= -f2- | tr -d '"')"
API_URL="$(echo "$STATUS" | grep '^API_URL=' | cut -d= -f2- | tr -d '"')"
SERVICE_KEY="$(echo "$STATUS" | grep '^SERVICE_ROLE_KEY=' | cut -d= -f2- | tr -d '"')"
case "$LOCAL_DB$API_URL" in
  *127.0.0.1*127.0.0.1*|*localhost*localhost*) ;;
  *) echo "Refusing to run: local stack does not look local." >&2; exit 1 ;;
esac

# ── cloud access (read-only, URL never printed) ────────────────────────────────────────────────
[ -f .env.clouddb ] || { echo ".env.clouddb not found." >&2; exit 1; }
set -a; . ./.env.clouddb; set +a
[ -n "${CLOUD_DB_URL:-}" ] || { echo "CLOUD_DB_URL missing in .env.clouddb." >&2; exit 1; }

redact() { sed -E 's#postgres(ql)?://[^ ]*#<url-redacted>#g'; }
# cloud_sql "<statements>" -> stdout (unaligned, tuples only), all inside a READ ONLY transaction.
cloud_sql() {
  { echo "BEGIN READ ONLY;"; echo "SET TRANSACTION READ ONLY;"; echo "$1;"; echo "ROLLBACK;"; } \
    | PGOPTIONS='-c default_transaction_read_only=on' psql "$CLOUD_DB_URL" -X -v ON_ERROR_STOP=1 -At -q 2> >(redact >&2)
}
# cloud_copy "<select>" <file>: \copy (SELECT ...) TO file CSV, read-only.
cloud_copy() {
  { echo "BEGIN READ ONLY;"; echo "SET TRANSACTION READ ONLY;"; echo "\\copy ($1) TO '$2' WITH (FORMAT csv)"; echo "ROLLBACK;"; } \
    | PGOPTIONS='-c default_transaction_read_only=on' psql "$CLOUD_DB_URL" -X -v ON_ERROR_STOP=1 -q 2> >(redact >&2)
}
local_sql() { psql "$LOCAL_DB" -X -v ON_ERROR_STOP=1 -At -q -c "$1"; }

# ── resolve the org (exactly one) ──────────────────────────────────────────────────────────────
ESC="${ORG_QUERY//\'/\'\'}"
MATCHES="$(cloud_sql "select id||'|'||name||'|'||slug from organizations where lower(slug) = lower('$ESC') or name ilike '%$ESC%'")"
N="$(printf '%s' "$MATCHES" | grep -c . || true)"
if [ "$N" -ne 1 ]; then echo "Expected exactly 1 matching organization, found $N. Aborting." >&2; exit 1; fi
ORG_ID="${MATCHES%%|*}"; REST="${MATCHES#*|}"; ORG_NAME="${REST%%|*}"; ORG_SLUG="${REST##*|}"
[[ "$ORG_ID" =~ ^[0-9a-f-]{36}$ ]] || { echo "Unexpected org id." >&2; exit 1; }
echo "==> Org: $ORG_NAME (slug $ORG_SLUG, id $ORG_ID)"

# ── private temp dir, always removed ───────────────────────────────────────────────────────────
umask 077
EXPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tenant-export.XXXXXX")"
trap 'rm -rf "$EXPORT_DIR"' EXIT

BR="(select id from branches where org_id='$ORG_ID')"
# table|filter (filter is applied identically on cloud for export and on local for the pre-delete)
TABLES=$(cat <<EOF
organizations|id='$ORG_ID'
branches|org_id='$ORG_ID'
users|org_id='$ORG_ID'
user_branches|branch_id in $BR
dentists|org_id='$ORG_ID'
chairs|branch_id in $BR
treatment_categories|org_id='$ORG_ID'
treatments|org_id='$ORG_ID'
customers|org_id='$ORG_ID'
membership_tiers|org_id='$ORG_ID'
memberships|org_id='$ORG_ID'
membership_transactions|org_id='$ORG_ID'
package_types|org_id='$ORG_ID'
packages|org_id='$ORG_ID'
voucher_types|org_id='$ORG_ID'
vouchers|org_id='$ORG_ID'
voucher_code_counters|org_id='$ORG_ID'
voucher_claims|org_id='$ORG_ID'
voucher_payments|org_id='$ORG_ID'
reward_catalog|org_id='$ORG_ID'
bookings|branch_id in $BR
booking_dentists|booking_id in (select id from bookings where branch_id in $BR)
payments|booking_id in (select id from bookings where branch_id in $BR)
payment_refunds|org_id='$ORG_ID'
package_redemptions|org_id='$ORG_ID'
treatment_notes|customer_id in (select id from customers where org_id='$ORG_ID')
customer_duplicate_dismissals|org_id='$ORG_ID'
customer_merge_log|org_id='$ORG_ID'
customer_referrals|org_id='$ORG_ID'
customer_referral_credits|org_id='$ORG_ID'
customer_referral_debits|org_id='$ORG_ID'
attendance|branch_id in $BR
dentist_attendance|branch_id in $BR
daily_reports|branch_id in $BR
audit_logs|branch_id in $BR
payroll_runs|branch_id in $BR
payroll_items|payroll_run_id in (select id from payroll_runs where branch_id in $BR)
staff_compensation|dentist_id in (select id from dentists where org_id='$ORG_ID')
notifications|user_id in (select id from users where org_id='$ORG_ID')
org_commission_collections|org_id='$ORG_ID'
org_commission_rates|org_id='$ORG_ID'
outreach_ai_config|org_id='$ORG_ID'
outreach_drafts|org_id='$ORG_ID'
outreach_messages|org_id='$ORG_ID'
outreach_rules|org_id='$ORG_ID'
outreach_templates|org_id='$ORG_ID'
EOF
)
# Local-only objects that hang off the org (migrations 001-005): cleared on reload, never exported.
LOCAL_ONLY_DELETE=$(cat <<EOF
manual_block_exceptions|series_id in (select series_id from manual_blocks where org_id='$ORG_ID' and series_id is not null)
manual_blocks|org_id='$ORG_ID'
staff_transfers|org_id='$ORG_ID'
EOF
)
# Columns forced to NULL on export (secrets / references to auth data we don't copy).
null_cols() {
  case "$1" in
    users) echo "pin" ;;
    org_commission_collections|org_commission_rates) echo "created_by" ;;
    bookings) echo "customer_account_id" ;;
    *) echo "" ;;
  esac
}

# ── column lists: intersection of cloud and local, excluding generated columns (schema drift) ────
cols_sql="select table_name||'|'||column_name from information_schema.columns where table_schema='public' and is_generated='NEVER' order by table_name, ordinal_position"
cloud_sql "$cols_sql" | sort > "$EXPORT_DIR/cloud_cols"
local_sql "$cols_sql" | sort > "$EXPORT_DIR/local_cols"

echo "==> Exporting (read-only) ..."
EXPORTED=""
while IFS='|' read -r T FILTER; do
  [ -n "$T" ] || continue
  NULLS=" $(null_cols "$T") "
  COLS=""
  while IFS= read -r C; do
    grep -qxF "$T|$C" "$EXPORT_DIR/cloud_cols" || { echo "   (drift) $T.$C exists locally only; left to default" >&2; continue; }
    if [[ "$NULLS" == *" $C "* ]]; then EXPR="NULL::text AS \"$C\""; else EXPR="\"$C\""; fi
    COLS="${COLS:+$COLS, }$EXPR"
  done < <(grep "^$T|" "$EXPORT_DIR/local_cols" | cut -d'|' -f2)
  comm -23 <(grep "^$T|" "$EXPORT_DIR/cloud_cols") <(grep "^$T|" "$EXPORT_DIR/local_cols") | sed 's/^/   (drift) cloud-only column skipped: /' >&2
  cloud_copy "select $COLS from public.\"$T\" where $FILTER" "$EXPORT_DIR/$T.csv"
  EXPORTED="$EXPORTED $T"
done <<< "$TABLES"

# Safety check on the export itself: only this org's id may appear as an org_id.
for T in $EXPORTED; do
  if grep -q "^$T|org_id$" "$EXPORT_DIR/local_cols"; then
    IDX=$(grep "^$T|" "$EXPORT_DIR/local_cols" | cut -d'|' -f2 | grep -nx org_id | cut -d: -f1)
    OTHERS=$(python3 - "$EXPORT_DIR/$T.csv" "$IDX" "$ORG_ID" <<'PY'
import csv, sys
bad = 0
with open(sys.argv[1], newline='') as f:
    for row in csv.reader(f):
        if row[int(sys.argv[2]) - 1] not in ('', sys.argv[3]): bad += 1
print(bad)
PY
)
    [ "$OTHERS" = "0" ] || { echo "ABORT: export of $T contains rows from another org." >&2; exit 1; }
  fi
done

# ── load locally in one transaction ────────────────────────────────────────────────────────────
echo "==> Loading into local DB (replica mode: FK checks + side-effect triggers off during load) ..."
{
  echo "BEGIN;"
  echo "SET session_replication_role = replica;"
  # delete this org's previous local copy (children first = reverse export order; local-only objects too)
  while IFS='|' read -r T FILTER; do [ -n "$T" ] && echo "DELETE FROM public.\"$T\" WHERE $FILTER;"; done <<< "$LOCAL_ONLY_DELETE"
  for T in $(echo $EXPORTED | tr ' ' '\n' | awk '{a[NR]=$0} END{for(i=NR;i>=1;i--)print a[i]}'); do
    F=$(echo "$TABLES" | grep "^$T|" | cut -d'|' -f2-)
    echo "DELETE FROM public.\"$T\" WHERE $F;"
  done
  echo "DELETE FROM auth.users WHERE email LIKE '%@${ORG_SLUG//-/}.local';"
  for T in $EXPORTED; do
    COLS=$(grep "^$T|" "$EXPORT_DIR/local_cols" | cut -d'|' -f2 | while read -r C; do grep -qxF "$T|$C" "$EXPORT_DIR/cloud_cols" && printf '"%s",' "$C"; done | sed 's/,$//')
    if [ "$T" = "bookings" ]; then
      # booking_number is globally unique; the local demo org's seed numbers (BK-<date>-000N) can collide with the
      # tenant's. Stage the tenant rows, rename any colliding NON-tenant local booking (suffix -L), then insert.
      echo "CREATE TEMP TABLE bk_stage (LIKE public.bookings INCLUDING DEFAULTS) ON COMMIT DROP;"
      echo "\\copy bk_stage ($COLS) FROM '$EXPORT_DIR/$T.csv' WITH (FORMAT csv)"
      echo "UPDATE public.bookings b SET booking_number = b.booking_number || '-L' FROM bk_stage s WHERE b.booking_number = s.booking_number;"
      echo "INSERT INTO public.bookings ($COLS) SELECT $COLS FROM bk_stage;"
    else
      echo "\\copy public.\"$T\" ($COLS) FROM '$EXPORT_DIR/$T.csv' WITH (FORMAT csv)"
    fi
  done
  # auth.users stubs so users -> auth.users foreign keys hold (no password, non-routable email)
  echo "INSERT INTO auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
        SELECT u.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', u.id::text || '@${ORG_SLUG//-/}.local', now(), now(), now(), '{}'::jsonb, '{}'::jsonb
        FROM public.users u WHERE u.org_id = '$ORG_ID' ON CONFLICT (id) DO NOTHING;"
  echo "COMMIT;"
} > "$EXPORT_DIR/load.sql"
psql "$LOCAL_DB" -X -v ON_ERROR_STOP=1 -q -f "$EXPORT_DIR/load.sql"

# ── verify: row counts cloud vs local, plus FK orphan check ────────────────────────────────────
echo "==> Row counts (cloud filtered by org  vs  local after import)"
MISMATCH=0
printf '%-32s %8s %8s\n' table cloud local
while IFS='|' read -r T FILTER; do
  [ -n "$T" ] || continue
  C=$(cloud_sql "select count(*) from public.\"$T\" where $FILTER")
  L=$(local_sql "select count(*) from public.\"$T\" where $FILTER")
  MARK=""; [ "$C" = "$L" ] || { MARK="  <-- MISMATCH"; MISMATCH=1; }
  printf '%-32s %8s %8s%s\n' "$T" "$C" "$L" "$MARK"
done <<< "$TABLES"
[ "$MISMATCH" = "0" ] || echo "WARNING: some counts differ" >&2

echo "==> Foreign-key orphan check (local, tenant tables)"
EXPORTED_ARR="$(echo $EXPORTED | sed "s/[^ ]*/'&'/g; s/ /,/g")"
ORPHAN_OUT="$(psql "$LOCAL_DB" -X -v ON_ERROR_STOP=1 -At -q 2>&1 <<SQL
DO \$\$
DECLARE r record; n bigint; bad int := 0;
BEGIN
  FOR r IN
    SELECT c.conrelid::regclass::text AS child, c.confrelid::regclass::text AS parent,
      (SELECT string_agg(format('c.%I IS NOT NULL', a.attname), ' AND ') FROM unnest(c.conkey) k JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=k) AS nn,
      (SELECT string_agg(format('p.%I = c.%I', pa.attname, ca.attname), ' AND ')
         FROM unnest(c.conkey, c.confkey) AS k(ck, pk)
         JOIN pg_attribute ca ON ca.attrelid=c.conrelid AND ca.attnum=k.ck
         JOIN pg_attribute pa ON pa.attrelid=c.confrelid AND pa.attnum=k.pk) AS jn,
      c.conname
    FROM pg_constraint c
    WHERE c.contype='f' AND c.connamespace='public'::regnamespace
      AND c.conrelid::regclass::text = ANY (ARRAY[$EXPORTED_ARR])
      AND c.confrelid::regclass::text NOT LIKE 'auth.%'
  LOOP
    EXECUTE format('SELECT count(*) FROM %s c WHERE %s AND NOT EXISTS (SELECT 1 FROM %s p WHERE %s)', r.child, r.nn, r.parent, r.jn) INTO n;
    IF n > 0 THEN RAISE NOTICE 'orphans: % -> % (%): %', r.child, r.parent, r.conname, n; bad := bad + 1; END IF;
  END LOOP;
  RAISE NOTICE 'FK orphan groups: %', bad;
END \$\$;
SQL
)"
echo "$ORPHAN_OUT" | sed 's/^/   /' | grep -E "orphans|orphan groups"

# ── local-only logins for the tenant ───────────────────────────────────────────────────────────
echo "==> Local test logins"
USERS_FILE="$REPO_ROOT/supabase/LOCAL_TEST_USERS.md"
SLUG_NOHYPHEN="${ORG_SLUG//-/}"
MAIN_BRANCH="$(local_sql "select id from branches where org_id='$ORG_ID' order by created_at limit 1")"
existing_pw() { [ -f "$USERS_FILE" ] && grep -F "| $1 |" "$USERS_FILE" | awk -F'|' '{gsub(/ |`/,"",$4); print $4}' | head -1 || true; }
SECTION="$(mktemp)"
for entry in "admin@${SLUG_NOHYPHEN}.test|Local Admin ($ORG_NAME)|admin" "manager@${SLUG_NOHYPHEN}.test|Local Manager ($ORG_NAME)|manager"; do
  IFS='|' read -r EMAIL NAME ROLE <<< "$entry"
  PW="$(existing_pw "$EMAIL")"; [ -n "$PW" ] || PW="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 16)Aa1"
  UID_="$(local_sql "select id from auth.users where email='$EMAIL'")"
  if [ -z "$UID_" ]; then
    UID_="$(curl -sS -X POST "$API_URL/auth/v1/admin/users" -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" -H 'Content-Type: application/json' \
      -d "{\"email\":\"$EMAIL\",\"password\":\"$PW\",\"email_confirm\":true}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')"
  else
    curl -sS -o /dev/null -X PUT "$API_URL/auth/v1/admin/users/$UID_" -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" -H 'Content-Type: application/json' -d "{\"password\":\"$PW\"}"
  fi
  psql "$LOCAL_DB" -X -v ON_ERROR_STOP=1 -q <<SQL
insert into public.users (id, email, full_name, role, branch_id, org_id, is_active)
values ('$UID_', '$EMAIL', '$NAME', '$ROLE', '$MAIN_BRANCH', '$ORG_ID', true)
on conflict (id) do update set role = excluded.role, branch_id = excluded.branch_id, org_id = excluded.org_id, is_active = true;
delete from public.user_branches where user_id = '$UID_';
SQL
  if [ "$ROLE" = "admin" ]; then
    psql "$LOCAL_DB" -X -q -c "insert into public.user_branches (user_id, branch_id) select '$UID_', id from public.branches where org_id='$ORG_ID' on conflict do nothing"
  else
    psql "$LOCAL_DB" -X -q -c "insert into public.user_branches (user_id, branch_id) values ('$UID_', '$MAIN_BRANCH') on conflict do nothing"
  fi
  echo "| $EMAIL | $ROLE | \`$PW\` |" >> "$SECTION"
done
# Replace this tenant's section in the (gitignored) users file; passwords stay out of the terminal.
touch "$USERS_FILE"
python3 - "$USERS_FILE" "$SECTION" "$ORG_NAME" "$ORG_SLUG" <<'PY'
import sys, re
path, section, name, slug = sys.argv[1:5]
body = open(path).read()
marker = f"\n## {name} (tenant copy)\n"
body = body.split(marker)[0].rstrip("\n") + "\n"
rows = open(section).read()
body += marker + f"\nLogin: http://localhost:<port>/{slug}/login — local-only copy of the cloud tenant.\n\n| Email | Role | Password |\n|---|---|---|\n" + rows
open(path, "w").write(body)
PY
rm -f "$SECTION"

echo "==> Done. Export files removed on exit. Log in at http://localhost:4029/$ORG_SLUG/login (npm run start:local)."
