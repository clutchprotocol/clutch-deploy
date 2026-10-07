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
# chain is up, and the compose file renders (compose's own message is not printed, because it can
# quote a line of the env file and the log is public: the script prints the command to run on the
# host). Then it pulls the pinned images of the three app services, starts the five services, and
# waits for each to be healthy.
#
# Safe to run again: `up -d` recreates only what changed, and a changed image pin or a changed value
# in .env.mainnet recreates that service. It never runs `down`, never takes `-v`, and has no reset:
# the treasury's two databases live in volumes of this project, and the chain beside it in project
# clutch-main. No port is published. nginx proxies /payment/ on the mainnet site to the orchestrator,
# which alone joins the stage network so that nginx can reach it. The orchestrator serves only the
# accounts of the pilot allowlist (PILOT_ALLOWED_ADDRESSES). This script ends by checking that it
# logged the allowlist as on, and then reloads nginx, which keeps the address it resolved for the
# orchestrator when it loaded its config and would answer 502 for a recreated one.

set -euo pipefail

cd "$(dirname "$0")/.."
. scripts/lib/chain.sh
. scripts/lib/mainnet-preflight.sh
chain_select mainnet

echo "=== preflight ($CH_ENV_FILE against .env.testnet) ==="
if ! preflight "$CH_ENV_FILE" .env.testnet; then
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
  echo "ABORT: the network clutch-mainnet does not exist. Start the chain first, with the workflow 'Mainnet — start the chain (irreversible)'."
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
if ! chain_compose config -q 2>/dev/null; then
  echo "ABORT: the compose file does not render with $CH_ENV_FILE. Its own message is not printed, because the log is public. Run on the host: docker compose -p $CH_PROJECT --env-file $CH_ENV_FILE -f docker-compose.mainnet.treasury.yml config -q"
  exit 1
fi
echo "  ok"

echo ""
echo "=== pulling the pinned images ==="
# Only the three app services, never the Postgres image: postgres:16-alpine is a floating tag, and a
# pull that moved it would make the next `up -d` recreate both databases.
if ! chain_compose pull "$CH_SVC_TREASURY" "$CH_SVC_SIGNER" "$CH_SVC_ORCH"; then
  echo "ABORT: pulling the pinned images failed (above). Nothing was started."
  exit 1
fi

echo ""
echo "=== starting ==="
if ! chain_compose up -d; then
  echo "ABORT: docker compose up failed (above). Containers it already started were left running; run PROBE=mainnet-treasury."
  exit 1
fi

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
echo "=== the orchestrator's pilot allowlist ==="
# The orchestrator logs one fixed line at start (payment-orchestrator, main.rs). An image from before
# the allowlist ignores APP_PILOT_ALLOWED_ADDRESSES without a word and serves every account, so a
# missing or different line is a failed start, however healthy the container looks. Only that fixed
# line is printed: it names a count and never an address, because the log of this workflow is public.
want=$(pf_get "$CH_ENV_FILE" PILOT_ALLOWED_ADDRESSES)
if [ "$want" = "*" ]; then
  expect="pilot allowlist: off, every account may use this service"
else
  expect="pilot allowlist: on, $(( $(printf '%s' "$want" | tr -cd ',' | wc -c) + 1 )) address(es)"
fi
got=$(docker logs "$CH_ORCH" 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' | grep -a "pilot allowlist:" | tail -n 1 \
        | sed -E 's/^.*(pilot allowlist: .*)$/\1/') || true
if [ "$got" = "$expect" ]; then
  echo "  $got"
else
  echo "  ABORT: the orchestrator should have logged \"$expect\" and logged \"${got:-nothing}\"."
  echo "  An orchestrator image from before the allowlist ignores the setting and would serve every"
  echo "  account. Do not point /payment/ at it. (A log level above info hides the line too.)"
  exit 1
fi

echo ""
echo "=== nginx reads the orchestrator's address again ==="
# nginx resolves the upstream name `mainnet-payment-orchestrator` when it loads its config and keeps
# that address. A recreated orchestrator can get another one, and /payment/ then answers 502 until
# something reloads nginx: the trap mainnet-app-up.yml closes for the hub API (about 5 minutes of 502
# on mainnet on 2026-09-25, with every other check green). It comes after the allowlist check on
# purpose: a start that finds the gate off ends above, before nginx is touched.
NGINX_C=$(docker ps --format '{{.Names}}' | grep -x 'nginx-stage' || true)
if [ -z "$NGINX_C" ]; then
  echo "ABORT: no running container named nginx-stage, so nothing could reload it. The treasury is up."
  exit 1
fi
if ! docker exec "$NGINX_C" nginx -t >/dev/null 2>&1; then
  echo "ABORT: nginx -t fails, so nginx was not reloaded. The treasury is up. Run on the host: docker exec $NGINX_C nginx -t"
  exit 1
fi
docker exec "$NGINX_C" nginx -s reload
echo "  nginx: reloaded"

echo ""
echo "started. No port is published. The orchestrator is on the stage network, so that nginx can reach"
echo "it, and /payment/ on the mainnet site goes to it. ($expect)"
