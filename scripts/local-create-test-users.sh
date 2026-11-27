#!/usr/bin/env bash
# Creates LOCAL-ONLY test logins for the seeded org (bright-smile-dental) on a local Supabase stack:
# GoTrue auth user + public.users profile + user_branches grant.
#
# Usage:
#   ./scripts/local-create-test-users.sh                    # this repo's stack; passwords file = the MAIN checkout's
#   ./scripts/local-create-test-users.sh --dry-run          # print the plan only (hosts, emails, roles); no network, no file
#   ./scripts/local-create-test-users.sh --workdir DIR      # another LOCAL stack: `supabase status` is run in DIR
#
# Passwords go to the MAIN checkout's supabase/LOCAL_TEST_USERS.md, or <DIR>'s with --workdir (gitignored, mode 600). Never
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

WORKDIR=""; DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --workdir)   [ $# -ge 2 ] || die "--workdir needs a directory"; WORKDIR="$2"; shift 2 ;;
    --workdir=*) WORKDIR="${1#--workdir=}"; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "unknown option: $1 (see --help)" ;;
  esac
done
if [ -n "$WORKDIR" ]; then
  # own separate stack: its own file
  [ -d "$WORKDIR" ] || die "--workdir is not a directory: '$WORKDIR'"
  WORKDIR="$(cd "$WORKDIR" && pwd)"
  [ -f "$WORKDIR/supabase/config.toml" ] || die "refusing: --workdir $WORKDIR has no supabase/config.toml"
  USERS_FILE="$WORKDIR/supabase/LOCAL_TEST_USERS.md"
else
  # CMD-111: every worktree shares one local stack, so the passwords file is the MAIN checkout's; a worktree never makes its own
  # (new passwords would be PUT to GoTrue and break everyone else's logins).
  WORKDIR="$REPO_ROOT"
  # capture git's output first: dirname of "" is ".", which would silently become the caller's cwd
  GIT_COMMON="$(cd "$REPO_ROOT" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && [ -n "$GIT_COMMON" ] || die "refusing: cannot find the main checkout with git. Nothing changed."
  MAIN="$(dirname "$GIT_COMMON")"
  USERS_FILE="$MAIN/supabase/LOCAL_TEST_USERS.md"
  if [ "$MAIN" != "$REPO_ROOT" ] && { [ ! -f "$USERS_FILE" ] || [ ! -w "$USERS_FILE" ]; }; then
    die "refusing: this is a worktree and the main checkout's $USERS_FILE is missing or not writable. Nothing changed."
  fi
fi
echo "local-create-test-users: passwords file: $USERS_FILE"

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

  "${PSQL[@]}" <<SQL
insert into public.users (id, email, full_name, role, branch_id, org_id, is_active)
values ('$uid', '$email', '$name', '$role', '$BRANCH_ID', '$ORG_ID', true)
on conflict (id) do update set role = excluded.role, branch_id = excluded.branch_id, org_id = excluded.org_id, is_active = true;
insert into public.user_branches (user_id, branch_id) values ('$uid', '$BRANCH_ID') on conflict do nothing;
SQL
  echo "| $email | $role | \`$pw\` |" >> "$TMP"
  echo "  $email ($role) ready"
done

mv "$TMP" "$USERS_FILE"
trap - EXIT
echo "==> Local test users ready on $DB_HOST (passwords in ${USERS_FILE#$REPO_ROOT/}, not shown)"
