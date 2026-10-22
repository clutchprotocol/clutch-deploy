#!/usr/bin/env bash
# Restart ONE validator that has stopped following the chain, and wait until it has caught up.
# Run on the stage host, from the repo root:
#
#   CHAIN=mainnet NODE=2 bash scripts/restart-validator.sh
#
# Made for a node whose process is alive but stuck: on 2026-10-20 at 04:43 UTC mainnet-node2
# stopped logging, importing and authoring at height 58641, while its container stayed "healthy"
# and Prometheus still scraped it. The other two kept the chain going, so the set could not be
# restarted with upgrade-validators.sh, which refuses unless all three agree first.
#
# It is a plain `docker restart` of that one container: same image, same config, same volume.
# Before anything is touched, the OTHER two must agree on one height and hash, and the stuck node
# must be at or below them. Afterwards it waits until all three agree, reads every node's log for
# refused blocks, and fails if either of the other two was restarted. Never `down`, never `-v`.
set -euo pipefail
cd "${REPO_DIR:-$(dirname "$0")/..}"

CHAIN="${CHAIN:?set CHAIN=stage or CHAIN=mainnet}"
NODE="${NODE:?set NODE=1, 2 or 3}"
# The node syncs every block it missed before it agrees again; 2.5 days was ~7,800 blocks.
CATCH_UP_SECS="${CATCH_UP_SECS:-1800}"
CURL_IMAGE=curlimages/curl:8.10.1

case "$NODE" in 1|2|3) ;; *) echo "NODE must be 1, 2 or 3" >&2; exit 2 ;; esac
case "$CHAIN" in
  stage)
    C="docker compose -p clutch-stage --env-file .env.testnet -f docker-compose.yml -f docker-compose.stage.cloudflare-flex.yml"
    NET=clutch-stage_clutch-network
    svc()     { echo "node$1"; }
    metrics() { echo "http://node$1:300$1/metrics"; }
    ;;
  mainnet)
    C="docker compose -p clutch-main --env-file .env.mainnet -f docker-compose.mainnet.yml"
    NET=clutch-mainnet
    svc()     { echo "mainnet-node$1"; }
    metrics() { echo "http://mainnet-node$1:310$1/metrics"; }
    ;;
  *) echo "CHAIN must be stage or mainnet" >&2; exit 2 ;;
esac

DISAGREE='author verification failed|wallet is not enabled|Sending from a wallet starts'

say() { printf '\n=== %s ===\n' "$1"; }
die() { printf '::error::%s\n' "$1"; exit 1; }

# "<height> <hash>" from a node's metrics, or nothing.
head_of() {
  docker run --rm --network "$NET" "$CURL_IMAGE" -fsS --max-time 5 "$(metrics "$1")" 2>/dev/null \
    | sed -n 's/^latest_block{block_hash="\([^"]*\)"} \(.*\)$/\2 \1/p' \
    | awk 'NF==2 {printf "%d %s\n", $1, $2; exit}'
}

container() { $C ps -q "$(svc "$1")" 2>/dev/null; }
started_at() { docker inspect -f '{{.State.StartedAt}}' "$(container "$1")"; }

describe() {
  local id; id=$(container "$1")
  [ -n "$id" ] || { echo "$(svc "$1"): not running"; return; }
  echo "$(svc "$1"): $(docker inspect -f '{{.Config.Image}} started {{.State.StartedAt}}' "$id") head $(head_of "$1" || echo '?')"
}

others=()
for i in 1 2 3; do [ "$i" = "$NODE" ] || others+=("$i"); done
A=${others[0]}; B=${others[1]}

say "before"
for i in 1 2 3; do describe "$i"; done
[ -n "$(container "$NODE")" ] || die "$(svc "$NODE") is not running; this script only restarts a running container"
for i in "$A" "$B"; do [ -n "$(container "$i")" ] || die "$(svc "$i") is not running; not touching $(svc "$NODE")"; done

# The other two must be one chain, or restarting the third could leave nobody authoritative.
deadline=$(( $(date +%s) + 120 ))
while :; do
  ha=$(head_of "$A" || true); hb=$(head_of "$B" || true)
  [ -n "$ha" ] && [ "$ha" = "$hb" ] && break
  [ "$(date +%s)" -lt "$deadline" ] || die "$(svc "$A") ($ha) and $(svc "$B") ($hb) do not agree; not starting"
  sleep 5
done
echo "$(svc "$A") and $(svc "$B") agree at $ha"
hn=$(head_of "$NODE" || true)
echo "$(svc "$NODE") is at ${hn:-?}"
[ -z "$hn" ] || [ "${hn%% *}" -le "${ha%% *}" ] || die "$(svc "$NODE") is AHEAD of the other two; not restarting it"
if [ -n "$hn" ] && [ "$hn" = "$ha" ]; then
  echo "::notice title=nothing to do::$(svc "$NODE") already agrees with the other two at $ha"
  exit 0
fi
sa=$(started_at "$A"); sb=$(started_at "$B")

say "restarting $(svc "$NODE")"
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
docker restart "$(container "$NODE")" >/dev/null
describe "$NODE"

say "waiting for $(svc "$NODE") to catch up (up to ${CATCH_UP_SECS}s)"
deadline=$(( $(date +%s) + CATCH_UP_SECS ))
last=""
while :; do
  a=$(head_of "$A" || true); b=$(head_of "$B" || true); n=$(head_of "$NODE" || true)
  if [ -n "$n" ] && [ "$a" = "$b" ] && [ "$n" = "$a" ]; then
    echo "all three at $n"
    break
  fi
  [ "$(date +%s)" -lt "$deadline" ] || die "$(svc "$NODE") did not catch up in ${CATCH_UP_SECS}s: it is at ${n:-?}, the others at ${a:-?} / ${b:-?}"
  [ "${n%% *}" = "$last" ] || { echo "$(svc "$NODE") at ${n:-?}, others at ${a:-?}"; last="${n%% *}"; }
  sleep 10
done

say "checks"
for j in 1 2 3; do
  c=$(docker logs --since "$started" "$(container "$j")" 2>&1 | grep -acE "$DISAGREE" || true)
  echo "$(svc "$j"): ${c:-0} refused block(s) since the restart"
  [ "${c:-0}" -eq 0 ] || die "$(svc "$j") refuses blocks: docker logs --since $started $(container "$j") | grep -E '$DISAGREE'"
done
[ "$(started_at "$A")" = "$sa" ] || die "$(svc "$A") was restarted during this run"
[ "$(started_at "$B")" = "$sb" ] || die "$(svc "$B") was restarted during this run"
echo "$(svc "$A") and $(svc "$B") were not touched"

say "after"
for i in 1 2 3; do describe "$i"; done
echo "::notice title=done::$(svc "$NODE") restarted and agrees with the other two."
