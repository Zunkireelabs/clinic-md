#!/usr/bin/env bash
# LOCAL ONLY. Proves agent_claim_jobs uses FOR UPDATE SKIP LOCKED with TWO real connections:
#   connection A claims 1 job and HOLDS its transaction open; connection B claims at the same time and must NOT get A's job (and must get others).
# It inserts 3 throwaway queued jobs (on existing bookings/playbooks) and deletes them afterwards. Refuses to run against anything but the local stack.
set -euo pipefail
DB_URL="$(supabase status -o env 2>/dev/null | grep '^DB_URL=' | cut -d= -f2- | tr -d '"')"
case "$DB_URL" in *127.0.0.1*|*localhost*) ;; *) echo "Refusing to run: DB_URL does not look local." >&2; exit 1 ;; esac
P() { psql "$DB_URL" -v ON_ERROR_STOP=1 -tAq "$@"; }
TAG="claimcheck-$$"
cleanup() { P -c "delete from public.agent_jobs where last_error = '$TAG'" >/dev/null || true; }
trap cleanup EXIT

P -c "insert into public.agent_jobs (org_id, branch_id, agent, playbook_id, event, booking_id, customer_id, run_after, last_error)
      select br.org_id, b.branch_id, 'follow_up', (select p.id from public.playbooks p where p.org_id = br.org_id and p.agent = 'follow_up' limit 1), 'day_before', b.id, b.customer_id, now() - interval '1 minute', '$TAG'
        from public.bookings b join public.branches br on br.id = b.branch_id
       where exists (select 1 from public.playbooks p where p.org_id = br.org_id and p.agent = 'follow_up')
         and not exists (select 1 from public.agent_jobs j where j.booking_id = b.id and j.event = 'day_before')
       limit 3" >/dev/null
N="$(P -c "select count(*) from public.agent_jobs where last_error = '$TAG'")"
[ "$N" -ge 2 ] || { echo "Need at least 2 throwaway jobs; found $N (no follow_up playbooks or bookings locally)." >&2; exit 1; }

A_OUT="$(mktemp)"
# connection A: claim ONE job, hold the transaction open for 6 seconds
( psql "$DB_URL" -tAq -c "begin; select (j ->> 'job_id') from public.agent_claim_jobs(1) j; select pg_sleep(6); rollback;" > "$A_OUT" 2>&1 ) &
sleep 2
# connection B: claim up to 10 while A still holds its lock
B_IDS="$(P -c "begin; select (j ->> 'job_id') from public.agent_claim_jobs(10) j; rollback;" | grep -E '^[0-9a-f-]{36}$' || true)"
wait
A_ID="$(grep -E '^[0-9a-f-]{36}$' "$A_OUT" | head -1 || true)"
rm -f "$A_OUT"
[ -n "$A_ID" ] || { echo "FAIL: connection A claimed nothing" >&2; exit 1; }
if echo "$B_IDS" | grep -q "$A_ID"; then echo "FAIL: connection B was handed the job connection A holds ($A_ID)" >&2; exit 1; fi
[ -n "$B_IDS" ] || { echo "FAIL: connection B claimed nothing (expected the other jobs)" >&2; exit 1; }
echo "PASS: A claimed $A_ID; B claimed $(echo "$B_IDS" | wc -l | tr -d ' ') other job(s) and skipped A's locked row."
