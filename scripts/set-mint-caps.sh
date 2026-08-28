#!/usr/bin/env bash
#
# Set the treasury's mint caps on stage and restart the service so it reads them.
#
#   PER_TX=1000000000 DAILY=2000000000 bash scripts/set-mint-caps.sh
#
# These are SAFETY LIMITS. Raising one is a deliberate act with a reason, and the reason belongs in
# the workflow log that invoked this. Put them back afterwards -- a cap raised "temporarily" and left
# is just a cap that no longer exists.
#
# Both matter: check_mint tests the per-transaction cap AND the rolling daily total, so a payment
# over the daily figure is refused even when the per-transaction one allows it.

set -euo pipefail

PER_TX="${PER_TX:?PER_TX must be set (micro-dollars; 1 USD = 1000000)}"
DAILY="${DAILY:?DAILY must be set (micro-dollars)}"

for v in "$PER_TX" "$DAILY"; do
  case "$v" in
    ''|*[!0-9]*) echo "ABORT: caps must be positive integers in micro-dollars, got '$v'."; exit 1;;
  esac
done
if [ "$PER_TX" -gt "$DAILY" ]; then
  echo "ABORT: per-transaction cap ($PER_TX) exceeds the daily cap ($DAILY)."
  echo "  A single mint could never clear both, so this combination refuses everything."
  exit 1
fi

if [ ! -f .env ]; then
  echo "ABORT: no .env here ($(pwd))."
  exit 1
fi

cp -a .env ".env.bak.$(date +%Y%m%d-%H%M%S)"
chmod 600 .env.bak.* 2>/dev/null || true

# Replace in place if present, append if not. sed -i on the file itself, NOT a mv: .env is
# bind-mounted by inode elsewhere in this stack and moving it silently detaches the mount.
set_var() {
  if grep -qE "^$1=" .env; then
    sed -i "s#^$1=.*#$1=$2#" .env
  else
    printf '%s=%s\n' "$1" "$2" >> .env
  fi
}

echo "=== before ==="
grep -E '^(PER_TX|DAILY)_MINT_CAP_CLT=' .env | sed 's/^/    /' || echo "    (unset — compose defaults: 50000000 / 500000000)"

set_var PER_TX_MINT_CAP_CLT "$PER_TX"
set_var DAILY_MINT_CAP_CLT "$DAILY"
chmod 600 .env

echo ""
echo "=== after ==="
grep -E '^(PER_TX|DAILY)_MINT_CAP_CLT=' .env | sed 's/^/    /'

# Recreate treasury-service so it reads the new environment. Only that service: nothing else
# consumes these, and recreating the whole stack restarts nodes for no reason.
echo ""
echo "=== restarting treasury-service ==="
docker compose -p clutch-stage \
  -f docker-compose.yml \
  -f docker-compose.treasury.yml \
  -f docker-compose.stage.cloudflare-flex.yml \
  -f docker-compose.stage.treasury.yml \
  up -d --force-recreate --no-deps treasury-service 2>&1 | tail -5

echo ""
echo "=== what the container now sees ==="
for i in $(seq 1 20); do
  v=$(docker exec clutch-stage-treasury-service-1 printenv APP_PER_TX_MINT_CAP_CLT 2>/dev/null || true)
  d=$(docker exec clutch-stage-treasury-service-1 printenv APP_DAILY_MINT_CAP_CLT 2>/dev/null || true)
  if [ -n "$v" ]; then
    echo "    APP_PER_TX_MINT_CAP_CLT=$v"
    echo "    APP_DAILY_MINT_CAP_CLT=$d"
    if [ "$v" = "$PER_TX" ] && [ "$d" = "$DAILY" ]; then
      echo ""
      echo "caps applied."
      exit 0
    fi
    echo "ABORT: the container is not reporting the values just written."
    exit 1
  fi
  sleep 2
done
echo "ABORT: treasury-service did not come back up."
exit 1
