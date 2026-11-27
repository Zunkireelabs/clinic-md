#!/usr/bin/env bash
# Creates LOCAL-ONLY test logins for the seeded org (bright-smile-dental) on a local Supabase stack:
# GoTrue auth user + public.users profile + user_branches grant.
#
# Usage:
#   ./scripts/local-create-test-users.sh                    # the stack `supabase status` reports for this repo
#   ./scripts/local-create-test-users.sh --dry-run          # print the plan only (hosts, emails, roles); no network, no file
#   ./scripts/local-create-test-users.sh --workdir DIR      # another LOCAL stack: `supabase status` is run in DIR
#
# Passwords are generated here and written to <workdir>/supabase/LOCAL_TEST_USERS.md (gitignored, mode 600). They are never
# printed, never put on a command line (curl reads them from stdin), and the file is never shown. Re-running reuses the passwords
# already in that file and is idempotent.
#
# Safety (CMD-110, shared with local-db-bootstrap.sh through scripts/lib/local-db-url.sh): `supabase status` runs in the workdir,
# never the caller's current directory; the DB URL AND the API URL must both have the host 127.0.0.1 or localhost (parsed, not a
# substring match), otherwise nothing is sent; the PG* connection variables are cleared and psql runs with -X.
set -euo pipefail
umask 077

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/local-db-url.sh
. "$REPO_ROOT/scripts/lib/local-db-url.sh"

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "local-create-test-users: $*" >&2; exit 1; }

WORKDIR="$REPO_ROOT"; DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --workdir)   [ $# -ge 2 ] || die "--workdir needs a directory"; WORKDIR="$2"; shift 2 ;;
    --workdir=*) WORKDIR="${1#--workdir=}"; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "unknown option: $1 (see --help)" ;;
  esac
done
[ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] || die "--workdir is not a directory: '$WORKDIR'"
WORKDIR="$(cd "$WORKDIR" && pwd)"
USERS_FILE="$WORKDIR/supabase/LOCAL_TEST_USERS.md"

STATUS="$(local_status_env "$WORKDIR")"
DB_URL="$(local_status_value "$STATUS" DB_URL)"
API_URL="$(local_status_value "$STATUS" API_URL)"
SERVICE_KEY="$(local_status_value "$STATUS" SERVICE_ROLE_KEY)"
unset STATUS
[ -n "$DB_URL" ] && [ -n "$API_URL" ] || die "could not read DB_URL / API_URL from 'supabase status' in $WORKDIR. Is that stack running?"
for check in "DB URL|$DB_URL" "API URL|$API_URL"; do
  local_require_local "${check%%|*}" "${check#*|}" 2>&1 | sed 's/^/local-create-test-users: /' >&2 || exit 1   # pipefail: the check's status
done
case "$DB_URL" in postgres://*|postgresql://*) ;; *) die "refusing to run: the DB URL is not a postgres URL" ;; esac
case "$API_URL" in http://*|https://*) ;; *) die "refusing to run: the API URL is not an http(s) URL" ;; esac
[ -n "$SERVICE_KEY" ] || die "could not read SERVICE_ROLE_KEY from 'supabase status' in $WORKDIR"
local_clear_pg_env
DB_HOST="$(local_url_host "$DB_URL")"; API_HOST="$(local_url_host "$API_URL")"

ORG_ID="00000000-0000-0000-0000-000000000001"
BRANCH_ID="00000000-0000-0000-0000-000000000101"

# email|full name|role
USERS=(
  "admin@clinicmd.test|Local Admin|admin"
  "manager@clinicmd.test|Local Branch Manager|manager"
  "staff@clinicmd.test|Local Front Desk|staff"
  "practitioner@clinicmd.test|Local Practitioner|practitioner"   # CMD-79: needs migration-011; linked to the first seeded dentist of the branch
)

# A saved password is reused only if it has the shape this script generates (letters and digits, 12+); anything else gets a new one,
# so a hand-edited file can never inject quotes into the curl config or the JSON body.
existing_pw() {
  local pw
  pw="$( { [ -f "$USERS_FILE" ] && grep -F "| $1 |" "$USERS_FILE" | head -n 1 | awk -F'|' '{gsub(/ |`/,"",$4); print $4}'; } || true)"
  case "$pw" in *[!A-Za-z0-9]*) return 0 ;; esac
  [ "${#pw}" -ge 12 ] && printf '%s\n' "$pw"
  return 0
}
is_uuid() { [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; }

if [ "$DRY_RUN" = 1 ]; then
  echo "local-create-test-users: DRY RUN, nothing is sent or written"
  echo "  stack: $WORKDIR (DB host $DB_HOST, API host $API_HOST)"
  echo "  passwords file: ${USERS_FILE#$REPO_ROOT/} ($( [ -f "$USERS_FILE" ] && echo 'exists' || echo 'will be created' ))"
  for entry in "${USERS[@]}"; do
    IFS='|' read -r email name role <<< "$entry"
    echo "  $email ($role): $( [ -n "$(existing_pw "$email")" ] && echo 'reuses its saved password' || echo 'gets a new password' )"
  done
  exit 0
fi

PSQL=(psql "$DB_URL" -X -q -v ON_ERROR_STOP=1)
"${PSQL[@]}" -Atc "select 1 from public.branches where id = '$BRANCH_ID' and org_id = '$ORG_ID'" | grep -q 1 \
  || die "the seeded org/branch ($ORG_ID / $BRANCH_ID) is not in the database on $DB_HOST. Run the bootstrap (seed.sql) first."

# The temp file sits next to the final file (same filesystem: the mv is a rename, no copy left in $TMPDIR), mode 600 from umask.
mkdir -p "$(dirname "$USERS_FILE")"
TMP="$(mktemp "$(dirname "$USERS_FILE")/.LOCAL_TEST_USERS.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
trap 'exit 1' INT TERM HUP
{
  echo "# Local test users (LOCAL ONLY — gitignored, never commit)"
  echo
  echo "Org: bright-smile-dental · Branch: Kathmandu Main · Login: http://localhost:<port>/bright-smile-dental/login"
  echo "These exist only in the local Docker Supabase (API $API_URL). Regenerated by \`scripts/local-create-test-users.sh\`."
  echo
  echo "| Email | Role | Password |"
  echo "|---|---|---|"
} > "$TMP"

# curl with the key and the body on stdin (a curl config), so neither shows up in `ps`.
# -q (first) skips ~/.curlrc; noproxy "*" ignores http(s)_proxy, so the request can only go to the checked local host.
api() {   # api METHOD PATH JSON -> prints "<body>\n<http code>"
  local q='"'
  curl -q -sS -K - -w '\n%{http_code}' <<CFG
noproxy = "*"
url = "$API_URL$2"
request = "$1"
header = "apikey: $SERVICE_KEY"
header = "Authorization: Bearer $SERVICE_KEY"
header = "Content-Type: application/json"
data = "${3//$q/\\$q}"
CFG
}
api_error() { python3 -c 'import sys, json
try: d = json.loads(sys.stdin.read() or "{}")
except Exception: d = {}
print(d.get("msg") or d.get("error_description") or d.get("message") or d.get("error_code") or d.get("code") or "no message")' ; }

for entry in "${USERS[@]}"; do
  IFS='|' read -r email name role <<< "$entry"
  pw="$(existing_pw "$email")"
  [ -n "$pw" ] || pw="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 16)Aa1"

  # Create (or update the password of) the GoTrue user via the local admin API.
  uid="$("${PSQL[@]}" -Atc "select id from auth.users where email = '$email'")"
  [ -z "$uid" ] || is_uuid "$uid" || die "unexpected auth.users id for $email"
  if [ -z "$uid" ]; then
    resp="$(api POST /auth/v1/admin/users "{\"email\":\"$email\",\"password\":\"$pw\",\"email_confirm\":true}")" || die "creating $email: the API call failed"
    code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
    case "$code" in 2??) ;; *) die "creating $email failed (HTTP $code): $(printf '%s' "$body" | api_error)" ;; esac
    uid="$(printf '%s' "$body" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("id", ""))' 2>/dev/null || true)"
  else
    resp="$(api PUT "/auth/v1/admin/users/$uid" "{\"password\":\"$pw\"}")" || die "updating $email: the API call failed"
    code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
    case "$code" in 2??) ;; *) die "updating $email failed (HTTP $code): $(printf '%s' "$body" | api_error)" ;; esac
  fi
  is_uuid "$uid" || die "no user id for $email from the API"

  # The practitioner role and users.dentist_id come from migration-011; without it, skip this login instead of failing the run.
  if [ "$role" = "practitioner" ] && [ "$("${PSQL[@]}" -Atc "select count(*) from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'user_role' and e.enumlabel = 'practitioner'")" = "0" ]; then
    echo "==> Skipping $email: migration-011 is not applied on this database" >&2
    continue
  fi

  "${PSQL[@]}" <<SQL
insert into public.users (id, email, full_name, role, branch_id, org_id, is_active)
values ('$uid', '$email', '$name', '$role', '$BRANCH_ID', '$ORG_ID', true)
on conflict (id) do update set role = excluded.role, branch_id = excluded.branch_id, org_id = excluded.org_id, is_active = true;
insert into public.user_branches (user_id, branch_id) values ('$uid', '$BRANCH_ID') on conflict do nothing;
SQL

  if [ "$role" = "practitioner" ]; then
    # link to the first seeded dentist of the branch that no other login is linked to (one profile, one login)
    "${PSQL[@]}" <<SQL
update public.users set dentist_id = (
  select d.id from public.dentists d
  where d.branch_id = '$BRANCH_ID' and d.org_id = '$ORG_ID'
    and (not exists (select 1 from public.users u where u.dentist_id = d.id and u.id <> '$uid'))
  order by d.display_order, d.name limit 1)
where id = '$uid';
SQL
  fi
  echo "| $email | $role | \`$pw\` |" >> "$TMP"
  echo "  $email ($role) ready"
done

mv "$TMP" "$USERS_FILE"
trap - EXIT
echo "==> Local test users ready on $DB_HOST (passwords in ${USERS_FILE#$REPO_ROOT/}, not shown)"
