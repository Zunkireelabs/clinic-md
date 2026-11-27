#!/bin/sh
# CMD-146 (migration 023): two sessions add DIFFERENT recordings to one consultation at the same moment: both pieces must survive, and
# both texts must be in the transcript. Session 1 holds its transaction open (pg_sleep) while session 2 calls the function: session 2 must
# wait on the row lock, then see session 1's piece. LOCAL DB ONLY; take /tmp/clinicmd-localdb.lock first. Seeds a test user and consultation (action_log is append-only, so the user and audit rows stay: run `supabase db reset` after).
URL="${RLS_DB_URL:-postgresql://postgres:postgres@127.0.0.1:55322/postgres}"
case "$URL" in *127.0.0.1*|*localhost*) ;; *) echo "refusing a non-local DB"; exit 2;; esac
Q() { psql "$URL" -X -v ON_ERROR_STOP=1 -Atq "$@"; }
ids=$(Q <<'SQL'
INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  VALUES ('00000000-0000-0000-0000-0000000c0023', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'conc023@test.invalid', now(), now());
INSERT INTO public.users (id, email, full_name, role, branch_id, org_id, is_active)
  SELECT '00000000-0000-0000-0000-0000000c0023', 'conc023@test.invalid', 'conc023', 'admin', b.branch_id, br.org_id, true
    FROM public.bookings b JOIN public.branches br ON br.id = b.branch_id ORDER BY b.created_at LIMIT 1;
INSERT INTO public.consultations (org_id, branch_id, booking_id, patient_name, status)
  SELECT br.org_id, b.branch_id, b.id, 'conc', 'draft' FROM public.bookings b JOIN public.branches br ON br.id = b.branch_id ORDER BY b.created_at LIMIT 1
  RETURNING id || ' ' || org_id || ' ' || booking_id;
SQL
) || { echo "seed failed"; exit 1; }
set -- $ids; C=$1; O=$2; B=$3
call() { # $1 path-suffix $2 text $3 sleep-seconds-after-call
  Q <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000c0023","role":"authenticated"}', true);
SELECT public.consultation_add_transcript_piece('$C', '$O/$B/$1.webm', '$2', 'en') ->> 'ok';
SELECT pg_sleep($3);
COMMIT;
SQL
}
call r1 "phone words" 3 & p1=$!
sleep 1
call r2 "desk words" 0 & p2=$!
wait $p1 $p2
res=$(Q -c "SELECT jsonb_array_length(transcript_pieces) || '|' || (transcript LIKE '%phone words%' AND transcript LIKE '%desk words%') FROM public.consultations WHERE id = '$C'")
Q <<SQL
DELETE FROM public.consultations WHERE id = '$C';
SQL
echo "pieces|both texts present: $res"
[ "$res" = "2|true" ] && echo "PASS: concurrent appends kept both pieces" || { echo "FAIL"; exit 1; }
