#!/bin/sh
# Tenant-isolation test. Exit code is psql's (not grep's), under bash and dash alike: no PIPESTATUS, which dash lacks.
out=$(psql "${RLS_DB_URL:-postgresql://postgres:postgres@127.0.0.1:55322/postgres}" -v ON_ERROR_STOP=1 -v verbose=off -f supabase/tests/tenant-isolation.sql)
rc=$?
printf '%s\n' "$out" | grep -E '^(FAIL|SUMMARY|COVERAGE)'
exit $rc
