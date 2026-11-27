#!/usr/bin/env bash
# LOCAL ONLY. Plays the part of an SMS gateway for the hub's TEST provider: it POSTs a SIGNED webhook to the local hub-inbound function (the same
# path a real provider uses), so delivery, read, failure, a reply and STOP can all be seen end to end. Needs scripts/local-hub-setup.sh first and
# `supabase functions serve --env-file supabase/functions/.env.hub.local` running.
#
#   scripts/local-hub-simulate.sh send                                    # run the sender now (what pg_cron does each minute)
#   scripts/local-hub-simulate.sh status <provider_message_id> delivered   # also: read | failed | sent
#   scripts/local-hub-simulate.sh reply  <patient number> "text"
#   scripts/local-hub-simulate.sh stop   <patient number>                  # a reply of exactly STOP
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/supabase/functions/.env.hub.local"
[ -f "$ENV_FILE" ] || { echo "Run scripts/local-hub-setup.sh first." >&2; exit 1; }

STATUS="$(supabase status -o env 2>/dev/null)"
DB_URL="$(echo "$STATUS" | grep '^DB_URL=' | cut -d= -f2- | tr -d '"')"
API_URL="$(echo "$STATUS" | grep '^API_URL=' | cut -d= -f2- | tr -d '"')"
case "$DB_URL$API_URL" in
  *127.0.0.1*127.0.0.1*|*localhost*localhost*) ;;
  *) echo "Refusing to run: stack does not look local." >&2; exit 1 ;;
esac

val() { grep "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-; }
SECRET="$(val HUB_TEST_WEBHOOK_SECRET)"; CRON="$(val CRON_BEARER_TOKEN)"
SENDER="$(psql "$DB_URL" -Atc "select sender from public.channel_accounts where provider = 'test' and status = 'connected' order by created_at limit 1")"
[ -n "$SENDER" ] || { echo "No connected test channel account." >&2; exit 1; }

post() { # $1 = JSON body
  local sig; sig="$(printf '%s' "$1" | openssl dgst -sha256 -hmac "$SECRET" -hex | sed 's/^.* //')"
  curl -sS -X POST "$API_URL/functions/v1/hub-inbound/test" -H "x-hub-signature: sha256=$sig" -H 'Content-Type: application/json' --data "$1"; echo
}
json() { python3 -c 'import json,sys; print(json.dumps(dict(a.split("=",1) for a in sys.argv[1:])))' "$@"; }

case "${1:-}" in
  send)   curl -sS -X POST "$API_URL/functions/v1/hub-send" -H "Authorization: Bearer $CRON" -H 'Content-Type: application/json' --data '{"mode":"send"}'; echo ;;
  status) post "$(json type=status id="$2" status="${3:-delivered}" to="$SENDER")" ;;
  reply)  post "$(json type=inbound from="$2" to="$SENDER" text="$3" id="sim-$(date +%s%N)")" ;;
  stop)   post "$(json type=inbound from="$2" to="$SENDER" text="STOP" id="sim-$(date +%s%N)")" ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
