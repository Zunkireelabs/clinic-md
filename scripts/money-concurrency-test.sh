#!/usr/bin/env bash
# CMD-115: concurrency proof for receipt numbering. LOCAL DB ONLY (refuses anything else); migration 021 must be applied.
# Builds a throwaway organisation, then runs act_money_collect from 20 SEPARATE connections at the same moment (a barrier: every
# connection waits on one advisory lock that is released once all are connected) and checks the numbers are exactly 1..20 with no gap
# or duplicate. Round 2 repeats with 20 more calls, 5 of which fail AFTER taking a number (a missing package is redeemed), and checks the
# numbers 21..35 are still gapless: a rolled-back collect uses no number.
# The BS calendar rows for today are throwaway FIXTURES (bs_year 2999, FIXTURE-NOT-CALENDAR-DATA) used only to give the numbering a fiscal year.
# Everything is removed by a cleanup trap (as the owner, with triggers off: a receipt is otherwise undeletable), and the script fails if any
# row with bs_year 2999 is left in bs_calendar.
# Usage: MONEY_DB_URL=postgresql://postgres:postgres@127.0.0.1:55322/<db> scripts/money-concurrency-test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
: "${MONEY_DB_URL:?set MONEY_DB_URL to a LOCAL database}"
case "$MONEY_DB_URL" in *@127.0.0.1:*|*@localhost:*) ;; *) echo "Refusing: not a local database." >&2; exit 1;; esac
N=20; LOCK=7711
WORK="$(mktemp -d)"
P() { psql "$MONEY_DB_URL" -v ON_ERROR_STOP=1 -q -At "$@"; }
[ "$(P -c "select to_regclass('public.money_documents') is not null")" = "t" ] || { echo "Apply migration 021 first." >&2; exit 1; }
[ "$(P -c "select count(*) from public.bs_calendar where bs_year = 2999")" = "0" ] || { echo "Fixture rows (bs_year 2999) already exist: refusing to start." >&2; exit 1; }

ORG=$(P -c "select gen_random_uuid()"); BR=$(P -c "select gen_random_uuid()"); UID_=$(P -c "select gen_random_uuid()")
SFX=$(P -c "select substr(replace(gen_random_uuid()::text,'-',''),1,8)")
FIX_TODAY=0

cleanup() {
  P <<SQL >/dev/null 2>&1
SET session_replication_role = replica;
DO \$\$ DECLARE t record; BEGIN
  FOR t IN SELECT table_name FROM information_schema.columns WHERE table_schema='public' AND column_name='branch_id' AND table_name <> 'branches' LOOP
    BEGIN EXECUTE format('DELETE FROM public.%I WHERE branch_id = %L', t.table_name, '$BR'); EXCEPTION WHEN others THEN NULL; END;
  END LOOP;
  FOR t IN SELECT table_name FROM information_schema.columns WHERE table_schema='public' AND column_name='org_id' AND table_name <> 'organizations' LOOP
    BEGIN EXECUTE format('DELETE FROM public.%I WHERE org_id = %L', t.table_name, '$ORG'); EXCEPTION WHEN others THEN NULL; END;
  END LOOP;
  DELETE FROM public.payments WHERE booking_id NOT IN (SELECT id FROM public.bookings);
  DELETE FROM public.user_branches WHERE user_id = '$UID_';
  DELETE FROM public.users WHERE id = '$UID_';
  DELETE FROM auth.users WHERE id = '$UID_';
  DELETE FROM public.branches WHERE id = '$BR';
  DELETE FROM public.organizations WHERE id = '$ORG';
  DELETE FROM public.bs_calendar WHERE bs_year = 2999;   -- FIXTURE-NOT-CALENDAR-DATA
END \$\$;
SQL
  rm -rf "$WORK"
  left=$(psql "$MONEY_DB_URL" -q -At -c "select count(*) from public.bs_calendar where bs_year = 2999" 2>/dev/null)
  if [ "$left" != "0" ]; then echo "FAIL: $left fixture bs_calendar row(s) (bs_year 2999) left behind" >&2; exit 1; fi
  echo "cleanup: fixtures removed, no bs_year 2999 row left"
}
trap cleanup EXIT

P <<SQL
INSERT INTO public.organizations (id, name, code, slug) VALUES ('$ORG', 'CONC test', 'cc$SFX', 'conc-$SFX');
DELETE FROM public.playbooks WHERE org_id = '$ORG'; DELETE FROM public.agent_settings WHERE org_id = '$ORG';
INSERT INTO public.branches (id, name, org_id) VALUES ('$BR', 'CONC', '$ORG');
INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at) VALUES ('$UID_', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'conc-$SFX@test.invalid', now(), now());
INSERT INTO public.users (id, email, full_name, role, branch_id, org_id, is_active) VALUES ('$UID_', 'conc-$SFX@test.invalid', 'CONC admin', 'admin', '$BR', '$ORG', true);
INSERT INTO public.dentists (branch_id, name, gender, org_id) VALUES ('$BR', 'Dr CONC', 'Male', '$ORG');
INSERT INTO public.treatments (name, duration_minutes, price_npr, org_id) VALUES ('T CONC', 30, 100, '$ORG');
INSERT INTO public.customers (branch_id, full_name, org_id) SELECT '$BR', 'Conc patient ' || g, '$ORG' FROM generate_series(1, 2 * $N) g;
-- FIXTURE-NOT-CALENDAR-DATA: today's fiscal year for the numbering only (kept only if the real table has no row for today)
INSERT INTO public.bs_calendar SELECT public._money_day(now()), 2999, 5, 10 WHERE NOT EXISTS (SELECT 1 FROM public.bs_calendar WHERE ad_date = public._money_day(now()));
INSERT INTO public.bookings (id, branch_id, treatment_id, customer_id, customer_name, date, start_time, end_time, start_datetime, end_datetime, base_amount, final_amount, status, payment_status, dentist_id)
SELECT gen_random_uuid(), '$BR', (SELECT id FROM public.treatments WHERE org_id = '$ORG'), c.id, c.full_name, public._money_day(now()),
       (time '07:00' + (row_number() OVER () * interval '1 minute')), (time '07:00' + (row_number() OVER () * interval '1 minute') + interval '1 minute'),
       now() + (row_number() OVER () * interval '1 minute'), now() + (row_number() OVER () * interval '1 minute') + interval '1 minute', 100, 100, 'Confirmed', 'unpaid',
       (SELECT id FROM public.dentists WHERE branch_id = '$BR')
  FROM public.customers c WHERE c.org_id = '$ORG';
SQL
BK=(); while IFS= read -r line; do BK+=("$line"); done < <(P -c "select id from public.bookings where branch_id = '$BR' order by customer_name")   # (bash 3.2: no mapfile)

run_round() {  # $1 = round (1|2), $2 = offset into BK, $3 = number of calls that must fail after taking a number
  local round="$1" off="$2" fails="$3" i pids=()
  psql "$MONEY_DB_URL" -q -At -c "select pg_advisory_lock($LOCK); select pg_sleep(4);" >/dev/null 2>&1 &
  local holder=$!
  sleep 1
  for ((i = 0; i < N; i++)); do
    local b="${BK[$((off + i))]}" mode='{"mode":"Cash","amount":100}'
    if (( i < fails )); then mode="{\"mode\":\"SessionPackage\",\"amount\":100,\"package_id\":\"$(P -c 'select gen_random_uuid()')\"}"; fi
    ( psql "$MONEY_DB_URL" -q -At <<SQL >"$WORK/r$round.$i" 2>&1
SELECT pg_advisory_lock_shared($LOCK);
SET ROLE authenticated; SELECT set_config('request.jwt.claims', '{"sub":"$UID_","role":"authenticated"}', false);
SELECT (r ->> 'ok') || '|' || coalesce(r #>> '{data,number}', r #>> '{error,code}') FROM (SELECT public.act_money_collect('[{"booking_id":"$b","amount":100}]'::jsonb, '[$mode]'::jsonb) AS r) x;
SQL
    ) & pids+=($!)
  done
  wait "${pids[@]}"; wait "$holder" 2>/dev/null
}

FYL=$(P -c "select fiscal_year(public._money_day(now()))")
fail=0
echo "round 1: $N concurrent collects"
run_round 1 0 0
okn=$(cat "$WORK"/r1.* | grep -c '^true|')
seqs=$(P -c "select string_agg(seq::text, ',' order by seq) from public.money_documents where org_id = '$ORG' and series = 'receipt'")
want=$(seq 1 $N | paste -sd, -)
echo "  ok: $okn of $N; numbers: $seqs"
[ "$okn" = "$N" ] && [ "$seqs" = "$want" ] && echo "  PASS gapless 1..$N, no duplicate" || { echo "  FAIL"; fail=1; }

echo "round 2: $N concurrent collects, 5 fail after taking a number"
run_round 2 $N 5
okn=$(cat "$WORK"/r2.* | grep -c '^true|'); badn=$(cat "$WORK"/r2.* | grep -c '^false|')
seqs=$(P -c "select string_agg(seq::text, ',' order by seq) from public.money_documents where org_id = '$ORG' and series = 'receipt'")
want=$(seq 1 $((N + N - 5)) | paste -sd, -)
echo "  ok: $okn, refused: $badn; numbers: $seqs"
[ "$okn" = "$((N - 5))" ] && [ "$badn" = "5" ] && [ "$seqs" = "$want" ] && echo "  PASS a rolled-back collect used no number: 1..$((N + N - 5)) gapless" || { echo "  FAIL"; fail=1; }
dups=$(P -c "select count(*) from (select number from public.money_documents where org_id = '$ORG' group by number having count(*) > 1) d")
[ "$dups" = "0" ] && echo "PASS no duplicate printed number (fiscal year $FYL)" || { echo "FAIL duplicate numbers: $dups"; fail=1; }
exit $fail
