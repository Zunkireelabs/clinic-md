# shellcheck shell=bash
# Shared LOCAL-ONLY checks for the scripts that write to a local Supabase stack (CMD-85, CMD-110).
# Sourced, not run:   . "$REPO_ROOT/scripts/lib/local-db-url.sh"
# Works with bash 3.2 (macOS /bin/bash). Every function prints its reason to stderr and RETURNS non-zero;
# the caller decides to exit. Nothing here prints a URL's password, a key or a password it was given.
#
#   local_url_host URL            -> prints the host of a postgres://, postgresql://, http:// or https:// URL, or fails
#   local_require_local KIND URL  -> fails unless the URL's host is exactly 127.0.0.1 or localhost (KIND names it in messages)
#   local_status_env DIR          -> prints `supabase status -o env` run IN DIR (never the caller's current directory)
#   local_status_value ENV NAME   -> the value of NAME= in that output, without quotes
#   local_clear_pg_env            -> unsets the PG* connection variables that could redirect psql

local_url_host() {
  local url="$1" rest authority query hostport host
  case "$url" in
    postgres://*|postgresql://*|http://*|https://*) ;;
    *) echo "the URL must start with postgres://, postgresql://, http:// or https://" >&2; return 1 ;;
  esac
  # Fail closed wherever this parse and libpq/curl could disagree (CMD-110 QC1):
  #  - '#': libpq has no fragment, so "?application_name=a#&host=remote" sets host in libpq but hid it from a '#' cut;
  #  - two '@': libpq splits user@host at the FIRST '@', this parse at the last;
  #  - '%' in a postgres query: libpq percent-decodes keywords, so "?h%6fst=remote" is host=remote.
  case "$url" in *'#'*) echo "'#' is not accepted in the URL" >&2; return 1 ;; esac
  rest="${url#*://}"
  authority="${rest%%[/?]*}"
  query=""; case "$rest" in *\?*) query="${rest#*\?}" ;; esac
  case "$authority" in *@*@*) echo "more than one '@' in the URL's host part" >&2; return 1 ;; esac
  hostport="${authority##*@}"
  case "$hostport" in \[*) echo "bracketed (IPv6) hosts are not accepted; use 127.0.0.1 or localhost" >&2; return 1 ;; esac
  # the comma check runs on host:port, BEFORE the port is cut off ("127.0.0.1:5432,remote:5432" is two hosts)
  case "$hostport" in *,*) echo "more than one host in the URL ($hostport)" >&2; return 1 ;; esac
  host="${hostport%%:*}"
  case "$url" in
    postgres://*|postgresql://*)
      case "$query" in *%*) echo "percent-encoding in the query is not accepted" >&2; return 1 ;; esac
      case "&$query" in
        *'&host='*|*'&hostaddr='*|*'&service='*) echo "the URL's query sets host, hostaddr or service, which can redirect the connection" >&2; return 1 ;;
      esac ;;
  esac
  printf '%s\n' "$host"
}

local_require_local() {
  local kind="$1" url="$2" host
  [ -n "$url" ] || { echo "refusing to run: the $kind is empty" >&2; return 1; }
  host="$(local_url_host "$url")" || { echo "refusing to run: the $kind is not usable (see above)" >&2; return 1; }
  case "$host" in
    127.0.0.1|localhost) return 0 ;;
    *) echo "refusing to run: the $kind host is '${host:-<empty>}', not 127.0.0.1 or localhost" >&2; return 1 ;;
  esac
}

local_status_env() {
  local dir="$1"
  [ -d "$dir" ] || { echo "no such directory: $dir" >&2; return 1; }
  # --workdir as well as cd: a SUPABASE_WORKDIR in the caller's environment must not pick another stack
  (cd "$dir" && supabase --workdir "$dir" status -o env 2>/dev/null) || true
}

local_status_value() {
  printf '%s\n' "$1" | grep "^$2=" | head -n 1 | cut -d= -f2- | tr -d '"' || true
}

local_clear_pg_env() {
  unset PGHOST PGHOSTADDR PGPORT PGDATABASE PGUSER PGSERVICE PGSERVICEFILE PGOPTIONS PGSSLMODE 2>/dev/null || true
}
