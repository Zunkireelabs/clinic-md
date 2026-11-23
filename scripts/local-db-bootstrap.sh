#!/usr/bin/env bash
# Bootstraps a LOCAL Supabase Postgres (started via `supabase start`) with this repo's schema, RLS policies, seed data and the
# numbered migrations, or steps an already bootstrapped local DB through a range of migrations. It never touches a cloud project.
#
# Usage:
#   supabase start                                   # once, to bring up the local stack
#   ./scripts/local-db-bootstrap.sh                  # schema.sql -> rls.sql -> seed.sql -> migration-NNN-*.sql -> test users
#   ./scripts/local-db-bootstrap.sh --dry-run        # print the plan only
#   ./scripts/local-db-bootstrap.sh --from 11 --to 16   # apply only migrations 011..016 to a DB that already has the rest
#   ./scripts/local-db-bootstrap.sh --to 0           # schema, RLS and seed only, no migrations
#   ./scripts/local-db-bootstrap.sh --db-url postgresql://postgres:postgres@127.0.0.1:54322/postgres   # another LOCAL stack
#
# To wipe and start over:   supabase db reset && ./scripts/local-db-bootstrap.sh
#
# Safety:
#   * The DB URL comes from --db-url or, without it, from `supabase status` run in this repo. There is NO other source and no fallback:
#     no .env file is read, and a --db-url that is given but empty or unusable stops the script.
#   * The URL's host must be exactly 127.0.0.1 or localhost (parsed, not a substring match); query parameters that can redirect the
#     connection (host, hostaddr, service) are refused, and the PG* connection variables are cleared so they cannot redirect psql either.
#   * Rollback (-rollback.sql) and preflight (-preflight.sql) files are never applied. Two forward files with the same number stop the
#     script (two PRs claimed the same migration number).
#   * Every file runs with ON_ERROR_STOP=1 and psql -X (no ~/.psqlrc). The first error stops the script and names the file.
#     A file without its own BEGIN/COMMIT runs as one transaction (psql -1); files that manage their own transaction run as written.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPABASE_DIR="$REPO_ROOT/supabase"

usage() { sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "local-db-bootstrap: $*" >&2; exit 1; }
is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

DB_URL=""; DB_URL_GIVEN=0; FROM=""; TO=""; DRY_RUN=0; NO_USERS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --db-url)   [ $# -ge 2 ] || die "--db-url needs a value"; DB_URL="$2"; DB_URL_GIVEN=1; shift 2 ;;
    --db-url=*) DB_URL="${1#--db-url=}"; DB_URL_GIVEN=1; shift ;;
    --from)     [ $# -ge 2 ] || die "--from needs a number"; FROM="$2"; shift 2 ;;
    --to)       [ $# -ge 2 ] || die "--to needs a number"; TO="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --no-users) NO_USERS=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "unknown option: $1 (see --help)" ;;
  esac
done
[ -z "$FROM" ] || is_num "$FROM" || die "--from must be a number, got '$FROM'"
[ -z "$TO" ]   || is_num "$TO"   || die "--to must be a number, got '$TO'"
if [ -n "$FROM" ] && [ -n "$TO" ] && [ $((10#$FROM)) -gt $((10#$TO)) ]; then die "--from ($FROM) is after --to ($TO)"; fi

# ── 1. the DB URL: --db-url, or `supabase status` in this repo; nothing else ──
if [ "$DB_URL_GIVEN" = 1 ]; then
  [ -n "$DB_URL" ] || die "--db-url was given but is empty; refusing to guess a URL"
else
  DB_URL="$(cd "$REPO_ROOT" && supabase status -o env 2>/dev/null | grep '^DB_URL=' | cut -d= -f2- | tr -d '"' || true)"
  [ -n "$DB_URL" ] || die "could not read DB_URL from 'supabase status' in $REPO_ROOT. Is the local stack running? Try 'supabase start'."
fi

# ── 2. the host must be local (parsed) ──
case "$DB_URL" in
  postgres://*|postgresql://*) ;;
  *) die "refusing to run: the DB URL must be a postgres:// or postgresql:// URL" ;;
esac
rest="${DB_URL#*://}"
authority="${rest%%[/?]*}"
query=""; case "$rest" in *\?*) query="${rest#*\?}" ;; esac
hostport="${authority##*@}"
case "$hostport" in \[*) die "refusing to run: bracketed (IPv6) hosts are not accepted; use 127.0.0.1 or localhost" ;; esac
host="${hostport%%:*}"
case "$host" in *,*) die "refusing to run: more than one host in the DB URL ($host)" ;; esac
case "&$query" in *'&host='*|*'&hostaddr='*|*'&service='*) die "refusing to run: the DB URL's query sets host, hostaddr or service, which can redirect the connection" ;; esac
case "$host" in
  127.0.0.1|localhost) ;;
  *) die "refusing to run: the DB host is '${host:-<empty>}', not 127.0.0.1 or localhost" ;;
esac
unset PGHOST PGHOSTADDR PGPORT PGDATABASE PGUSER PGSERVICE PGSERVICEFILE PGOPTIONS PGSSLMODE 2>/dev/null || true

# ── 3. the plan ──
PLAN=()
if [ -z "$FROM" ]; then
  for f in schema.sql rls.sql; do PLAN+=("$SUPABASE_DIR/$f"); done
  for f in "$REPO_ROOT"/scripts/local-only-supplemental-*.sql; do [ -e "$f" ] && PLAN+=("$f"); done   # local gap fillers, if any
  PLAN+=("$SUPABASE_DIR/seed.sql")
fi
# forward migrations as "<number><TAB><path>", in numeric order (a function: bash 3.2 misparses 10#$n inside $( ))
list_migrations() {
  local f b n
  for f in "$SUPABASE_DIR"/migration-[0-9]*.sql; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    case "$b" in *-rollback.sql|*-preflight.sql) continue ;; esac
    n="${b#migration-}"; n="${n%%-*}"
    is_num "$n" || die "cannot read the migration number of $b"
    printf '%d\t%s\n' "$((10#$n))" "$f"
  done | sort -n -k1,1
}
MIG_LIST="$(list_migrations)"
dups="$(printf '%s\n' "$MIG_LIST" | awk -F'\t' 'NF { c[$1]++; f[$1] = f[$1] " " $2 } END { for (n in c) if (c[n] > 1) print n ":" f[n] }')"
[ -z "$dups" ] || die "two forward migrations share a number, fix that first: $dups"
while IFS="$(printf '\t')" read -r n f; do
  [ -n "$n" ] || continue
  if [ -n "$FROM" ] && [ "$n" -lt $((10#$FROM)) ]; then continue; fi
  if [ -n "$TO" ] && [ "$n" -gt $((10#$TO)) ]; then continue; fi
  PLAN+=("$f")
done <<EOF
$MIG_LIST
EOF
[ ${#PLAN[@]} -gt 0 ] || die "nothing to apply for --from ${FROM:-start} --to ${TO:-end}"

RUN_USERS=0
if [ -z "$FROM" ] && [ "$NO_USERS" = 0 ] && [ -x "$REPO_ROOT/scripts/local-create-test-users.sh" ]; then
  if [ "$DB_URL_GIVEN" = 0 ]; then RUN_USERS=1; fi
fi

echo "local-db-bootstrap: host $host, $( [ "$DRY_RUN" = 1 ] && echo 'DRY RUN, nothing is applied' || echo "${#PLAN[@]} file(s) to apply" )"
i=0
for f in "${PLAN[@]}"; do i=$((i + 1)); printf '  %2d. %s\n' "$i" "${f#$REPO_ROOT/}"; done
if [ "$RUN_USERS" = 1 ]; then echo "  then scripts/local-create-test-users.sh"
elif [ -z "$FROM" ] && [ "$NO_USERS" = 0 ] && [ "$DB_URL_GIVEN" = 1 ]; then
  echo "  test users skipped: --db-url was given, and local-create-test-users.sh only targets the stack from 'supabase status'"
fi
[ "$DRY_RUN" = 0 ] || exit 0

# ── 4. apply ──
PSQL=(psql "$DB_URL" -X -q -v ON_ERROR_STOP=1)
if [ -z "$FROM" ]; then
  existing="$("${PSQL[@]}" -Atc "select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname in ('organizations', 'bookings')")" \
    || die "cannot connect to the database on $host"
  [ "$existing" = 0 ] || die "the database on $host already has the schema (public.organizations / bookings). Run 'supabase db reset' first, or step migrations with --from N."
fi

START=$SECONDS
APPLIED=()
for f in "${PLAN[@]}"; do
  rel="${f#$REPO_ROOT/}"
  echo "==> $rel"
  if grep -qiE '^[[:space:]]*(BEGIN|COMMIT|ROLLBACK)[[:space:]]*;' "$f"; then single=(); else single=(-1); fi
  if ! "${PSQL[@]}" ${single[@]+"${single[@]}"} -f "$f"; then
    echo >&2
    echo "local-db-bootstrap: FAILED on $rel. Stopped; nothing after it was applied." >&2
    [ ${#APPLIED[@]} -eq 0 ] || { echo "Applied before it:" >&2; for a in "${APPLIED[@]}"; do echo "  $a" >&2; done; }
    exit 1
  fi
  APPLIED+=("$rel")
done

if [ "$RUN_USERS" = 1 ]; then
  echo "==> scripts/local-create-test-users.sh"
  "$REPO_ROOT/scripts/local-create-test-users.sh"
fi

echo
echo "local-db-bootstrap: done in $((SECONDS - START))s on $host. Applied ${#APPLIED[@]} file(s):"
for a in "${APPLIED[@]}"; do echo "  $a"; done
[ "$RUN_USERS" = 0 ] || echo "  + test users (scripts/local-create-test-users.sh)"
