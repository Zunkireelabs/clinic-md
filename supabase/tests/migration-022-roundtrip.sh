#!/usr/bin/env bash
# CMD-62: backfill and rollback round trip for migration 022. LOCAL, THROWAWAY DATABASES ONLY.
#   supabase/tests/migration-022-roundtrip.sh postgresql://postgres:postgres@127.0.0.1:55322/<throwaway db>
# The database must hold 001-018 (022 may or may not be applied: this script puts it back to the pre-022 state first, which DROPS user_pins).
# It refuses any host but 127.0.0.1 and the database named postgres. Seeds its own organization and users (plain PINs), then:
#   1. applies 022 and checks the backfill: no plain pin left, every former PIN verifies, '' and NULL give no hash;
#   2. runs the rollback: old function bodies back, trigger and new functions gone, user_pins and the hashes KEPT, users.pin NULL;
#   3. applies 022 again (roll forward) and checks that the former PINs still log in.
set -euo pipefail
URL="${1:?usage: $0 <local db url>}"
case "$URL" in postgresql://*@127.0.0.1:*/*) ;; *) echo "refusing: not a local 127.0.0.1 URL" >&2; exit 2;; esac
DB="${URL##*/}"; [ "$DB" != "postgres" ] || { echo "refusing: use a throwaway database, not postgres" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")/.." && pwd)"
Q() { psql "$URL" -v ON_ERROR_STOP=1 -At -q "$@"; }
FAILS=0
chk() { if [ "$2" = "t" ]; then echo "PASS  $1"; else echo "FAIL  $1  (got: $2)"; FAILS=$((FAILS+1)); fi; }

echo "== 0. back to the pre-022 state"
if [ "$(Q -c "select to_regclass('public.user_pins') is not null")" = "t" ]; then
  Q -f "$HERE/migration-022-rollback.sql" >/dev/null; Q -c "DROP TABLE public.user_pins"
fi
SFX=$(Q -c "select substr(replace(gen_random_uuid()::text,'-',''),1,8)")
Q <<SQL
DO \$\$
DECLARE o uuid := gen_random_uuid(); b uuid := gen_random_uuid(); r record;
BEGIN
  INSERT INTO organizations (id, name, code, slug) VALUES (o, 'RT org', 'rt$SFX', 'rt-$SFX');
  INSERT INTO branches (id, name, org_id) VALUES (b, 'RT branch', o);
  FOR r IN SELECT * FROM (VALUES ('p2468', '2468'), ('p0000', '0000'), ('p123456', '123456'), ('pempty', ''), ('pnull', NULL)) v(k, pin) LOOP
    WITH a AS (INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at)
               VALUES (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rt-' || r.k || '-$SFX@test.invalid', now(), now()) RETURNING id)
    INSERT INTO public.users (id, email, full_name, role, branch_id, org_id, is_active, pin) SELECT id, 'rt-' || r.k || '-$SFX@test.invalid', r.k, 'staff', b, o, true, r.pin FROM a;
  END LOOP;
END \$\$;
SQL
chk "seeded 5 users, 3 with a PIN, 1 empty string, 1 NULL" "$(Q -c "select (count(*) = 5 and count(*) filter (where pin <> '') = 3 and count(*) filter (where pin = '') = 1) from public.users where email like 'rt-%-$SFX@test.invalid'")"
BEFORE_USERS=$(Q -c "select count(*) from public.users")

login() { Q -c "select (public.login_with_pin('rt-$1-$SFX@test.invalid', '$2', 'rt-$SFX')::json ->> 'success')"; }

echo "== 1. apply 022 (backfill)"
Q -f "$HERE/migration-022-staff-pin.sql" >/dev/null
chk "no row of public.users has a non-NULL pin (any user, any org)" "$(Q -c "select count(*) = 0 from public.users where pin is not null")"
chk "3 hashes for the 3 seeded PINs, none for '' or NULL" "$(Q -c "select count(*) = 3 from public.user_pins p join public.users u on u.id = p.user_id where u.email like 'rt-%-$SFX@test.invalid' and p.pin_hash like '\$2%'")"
chk "every former PIN verifies: 2468" "$(login p2468 2468 | sed 's/^true$/t/')"
chk "every former PIN verifies: 0000 (weak, carried over)" "$(login p0000 0000 | sed 's/^true$/t/')"
chk "every former PIN verifies: 123456 (not 4 digits, carried over)" "$(login p123456 123456 | sed 's/^true$/t/')"
chk "the empty-string user cannot log in" "$([ "$(login pempty '')" = "false" ] && echo t || echo no)"
chk "the NULL user cannot log in" "$([ "$(login pnull 0000)" = "false" ] && echo t || echo no)"
chk "a wrong PIN does not log in" "$([ "$(login p2468 9999)" = "false" ] && echo t || echo no)"
chk "no users row was added or lost by the migration" "$([ "$(Q -c "select count(*) from public.users")" = "$BEFORE_USERS" ] && echo t || echo no)"

echo "== 2. rollback"
Q -f "$HERE/migration-022-rollback.sql" >/dev/null
chk "user_pins and its hashes are KEPT" "$(Q -c "select count(*) >= 3 from public.user_pins")"
chk "users.pin is NULL for every row (plain PINs are not restored)" "$(Q -c "select count(*) = 0 from public.users where pin is not null")"
chk "set_my_pin, admin_reset_pin, the helpers and the trigger are gone" "$(Q -c "select not exists (select 1 from pg_proc where proname in ('set_my_pin','admin_reset_pin','_pin_try','_pin_random','_pin_is_trivial','_users_hash_plain_pin')) and not exists (select 1 from pg_trigger where tgname = 'users_hash_plain_pin')")"
chk "login_with_pin, verify_pin, list_discount_approvers have their old bodies (compare users.pin)" "$(Q -c "select bool_and(prosrc like '%u.pin%') from pg_proc where proname in ('login_with_pin','verify_pin','list_discount_approvers')")"
chk "grants unchanged: login_with_pin/verify_pin service_role only" "$(Q -c "select bool_and(has_function_privilege('service_role', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute') and not has_function_privilege('authenticated', p.oid, 'execute')) from pg_proc p where proname in ('login_with_pin','verify_pin')")"
chk "(stated consequence) PIN login works for nobody after the rollback" "$([ "$(login p2468 2468)" = "false" ] && echo t || echo no)"

echo "== 3. roll forward again"
Q -f "$HERE/migration-022-staff-pin.sql" >/dev/null
chk "the former PINs log in again from the kept hashes: 2468" "$(login p2468 2468 | sed 's/^true$/t/')"
chk "the former PINs log in again from the kept hashes: 123456" "$(login p123456 123456 | sed 's/^true$/t/')"
chk "still no plain pin anywhere" "$(Q -c "select count(*) = 0 from public.users where pin is not null")"

echo; [ "$FAILS" = 0 ] && echo "ROUNDTRIP OK" || { echo "ROUNDTRIP: $FAILS FAIL(s)"; exit 1; }
