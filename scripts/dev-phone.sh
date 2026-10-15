#!/usr/bin/env bash
# Start the dev server with a trusted https address for phones (Cloudflare quick
# tunnel). The tunnel address changes every run, so this starts the tunnel,
# writes it to .env.local as VITE_PUBLIC_APP_URL (what the consultation QR code
# points at), then starts Vite. Requires: brew install cloudflared
set -euo pipefail
cd "$(dirname "$0")/.."

command -v cloudflared >/dev/null || { echo "Install cloudflared first: brew install cloudflared"; exit 1; }

LOG="$(mktemp)"
cloudflared tunnel --url http://localhost:4028 >"$LOG" 2>&1 &
TUNNEL_PID=$!
trap 'kill $TUNNEL_PID 2>/dev/null' EXIT

URL=""
for _ in $(seq 1 30); do
  URL="$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$LOG" | head -1 || true)"
  [ -n "$URL" ] && break
  sleep 1
done
[ -n "$URL" ] || { echo "Tunnel did not start. See $LOG"; exit 1; }

touch .env.local
grep -v '^VITE_PUBLIC_APP_URL=' .env.local > .env.local.tmp || true
echo "VITE_PUBLIC_APP_URL=$URL" >> .env.local.tmp
mv .env.local.tmp .env.local

echo "Phone address: $URL"
npm start
