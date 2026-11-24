#!/usr/bin/env bash
# CMD-115: round-trip proof for migration 021. LOCAL DB ONLY (refuses anything else).
# Seeds a few payments / refunds / closings, snapshots the public schema and row checksums, applies 021, rolls it back,
# snapshots again and compares: the schema dump must be identical (apart from pg_dump's random \restrict token) and every
# old row must be unchanged. Needs 021 NOT applied when it starts (run the rollback first if it is).
# Usage: MONEY_DB_URL=postgresql://postgres:postgres@127.0.0.1:55322/<db> scripts/money-roundtrip.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
: "${MONEY_DB_URL:?set MONEY_DB_URL to a LOCAL database}"
case "$MONEY_DB_URL" in *@127.0.0.1:*|*@localhost:*) ;; *) echo "Refusing: not a local database." >&2; exit 1;; esac
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
P() { psql "$MONEY_DB_URL" -v ON_ERROR_STOP=1 -q -At "$@"; }
if [ "$(P -c "select to_regclass('public.money_documents') is not null")" = "t" ]; then echo "021 is already applied: run migration-021-rollback.sql first." >&2; exit 1; fi

# fixtures (tagged ROUNDTRIP; removed at the end)
P <<'SQL'
DO $$ DECLARE u uuid := gen_random_uuid(); br uuid; o uuid; b uuid; b2 uuid;
BEGIN
  SELECT id, org_id INTO br, o FROM public.branches ORDER BY id LIMIT 1;
  INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at) VALUES (u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'roundtrip@test.invalid', now(), now());
  INSERT INTO public.users (id, email, full_name, role, branch_id, org_id, is_active) VALUES (u, 'roundtrip@test.invalid', 'ROUNDTRIP', 'manager', br, o, true);
  SELECT id INTO b FROM public.bookings WHERE branch_id = br AND is_locked = false AND final_amount >= 100 ORDER BY id LIMIT 1;
  SELECT id INTO b2 FROM public.bookings WHERE branch_id = br AND id <> b ORDER BY id LIMIT 1;
  INSERT INTO public.payments (booking_id, amount, payment_mode, recorded_by, notes, created_at) VALUES (b, 60, 'Cash', u, 'ROUNDTRIP', now() - interval '3 days'), (b, 40, 'Esewa', u, 'ROUNDTRIP', now() - interval '2 days');
  INSERT INTO public.payment_refunds (booking_id, org_id, amount, refunded_by, reason) VALUES (b, o, 10, u, 'ROUNDTRIP');
  INSERT INTO public.daily_reports (branch_id, report_date, closed_by) VALUES (br, current_date - 30, u);
END $$;
SQL
snap() {
  pg_dump "$MONEY_DB_URL" --schema-only -n public | grep -v '^\\\(un\)\?restrict ' > "$WORK/$1.sql"
  P -c "select 'payments', count(*), md5(coalesce(string_agg(t::text,'|' order by id),'')) from (select id,booking_id,amount,payment_mode,recorded_by,notes,created_at from payments) t
        union all select 'payment_refunds', count(*), md5(coalesce(string_agg(t::text,'|' order by id),'')) from (select id,booking_id,org_id,amount,refunded_by,reason,created_at from payment_refunds) t
        union all select 'daily_reports', count(*), md5(coalesce(string_agg(t::text,'|' order by id),'')) from (select id,branch_id,report_date,total_bookings,completed_bookings,cancelled_bookings,gross_revenue,total_discounts,net_revenue,cash_total,card_total,fonepay_total,unpaid_count,closed_by,closed_at,is_locked from daily_reports) t" > "$WORK/$1.rows"
}
snap before
P -f supabase/migration-021-money-data.sql >/dev/null
P -f supabase/migration-021-rollback.sql >/dev/null
snap after
rc=0
diff "$WORK/before.sql" "$WORK/after.sql" > "$WORK/schema.diff" && echo "SCHEMA: identical" || { echo "SCHEMA: DIFFERENT"; head -40 "$WORK/schema.diff"; rc=1; }
diff "$WORK/before.rows" "$WORK/after.rows" >/dev/null && echo "ROWS: identical (counts + md5)" || { echo "ROWS: DIFFERENT"; rc=1; }
cat "$WORK/before.rows"
# cleanup of the fixtures
P <<'SQL'
DELETE FROM public.payment_refunds WHERE reason = 'ROUNDTRIP';
DELETE FROM public.payments WHERE notes = 'ROUNDTRIP';
DELETE FROM public.daily_reports WHERE closed_by IN (SELECT id FROM public.users WHERE full_name = 'ROUNDTRIP');
DELETE FROM public.users WHERE full_name = 'ROUNDTRIP';
DELETE FROM auth.users WHERE email = 'roundtrip@test.invalid';
SQL
exit $rc
