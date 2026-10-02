#!/usr/bin/env bash
#
# Start, or bring up to date, the MAINNET treasury: docker-compose.mainnet.treasury.yml, compose
# project clutch-main-treasury, env file .env.mainnet. The workflow "Mainnet — start the treasury"
# runs it.
#
#   bash scripts/mainnet-treasury-up.sh
#
# It starts nothing until every check has passed, in this order: the preflight (the env files),
# check-cap-invariants.sh on the mainnet file (the limits and the GasFree settings agree), the mainnet
# chain is up, and the compose file renders (compose names any missing setting). Then it pulls the
# pinned images, starts the five services, and waits for each to be healthy.
#
# Safe to run again: `up -d` recreates only what changed. It never runs `down`, never takes `-v`, and
# has no reset: the treasury's two databases live in volumes of this project, and the chain beside it
# in project clutch-main. NOTHING reaches the result from outside: no port is published, no stage
# network is joined, and /payment/ on the mainnet site still answers 503.

set -euo pipefail

cd "$(dirname "$0")/.."
. scripts/lib/chain.sh
. scripts/lib/mainnet-preflight.sh
chain_select mainnet

echo "=== preflight ($CH_ENV_FILE against .env) ==="
if ! preflight "$CH_ENV_FILE" .env; then
  echo ""
  echo "ABORT: the preflight found problems (above). Nothing was started."
  exit 1
fi

echo ""
echo "=== the limits and the GasFree settings agree ==="
if ! ENV_FILE="$CH_ENV_FILE" bash scripts/check-cap-invariants.sh; then
  echo ""
  echo "ABORT: check-cap-invariants.sh found a broken relationship (above). Nothing was started."
  exit 1
fi

echo ""
echo "=== the mainnet chain is up ==="
if ! docker network inspect clutch-mainnet >/dev/null 2>&1; then
  echo "ABORT: the network clutch-mainnet does not exist. Start the chain first (Mainnet — start the chain)."
  exit 1
fi
names=$(docker ps --format '{{.Names}}')
case "$names" in
  *mainnet-node3*) ;;
  *) echo "ABORT: no mainnet-node3 container is running. The treasury reads the chain through it."; exit 1 ;;
esac
echo "  clutch-mainnet exists, mainnet-node3 is running"

echo ""
echo "=== the compose file renders ==="
chain_compose config -q
echo "  ok"

echo ""
echo "=== pulling the pinned images ==="
chain_compose pull

echo ""
echo "=== starting ==="
chain_compose up -d

echo ""
echo "=== waiting for health ==="
unhealthy=0
for c in "$CH_TREASURY_PG" "$CH_ORCH_PG" "$CH_ORCH" "$CH_TREASURY" "$CH_SIGNER"; do
  status=none
  for _ in $(seq 1 60); do
    status=$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || echo none)
    [ "$status" = healthy ] && break
    sleep 2
  done
  if [ "$status" = healthy ]; then
    echo "  $c healthy"
  else
    # No service log here: the log of this workflow is public, and a service log can hold a user's address or an identifier. The operator reads it on the host.
    echo "  $c is not healthy ($status). Read its log on the host: docker logs --tail 50 $c"
    unhealthy=1
  fi
done

echo ""
echo "=== containers ==="
docker ps --filter "label=com.docker.compose.project=$CH_PROJECT" --format '  {{.Names}}  {{.Status}}  {{.Image}}'

if [ "$unhealthy" -ne 0 ]; then
  echo ""
  echo "ABORT: not every service is healthy. Nothing was stopped; read the logs on the host (the commands are above), or run PROBE=mainnet-treasury."
  exit 1
fi

echo ""
echo "started. Nothing reaches it from outside: no port is published, no stage network is joined,"
echo "and /payment/ on the mainnet site still answers 503."
