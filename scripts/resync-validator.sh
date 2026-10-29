#!/usr/bin/env bash
# Wipe ONE stage validator's chain data and let it sync again from the other two.
# Run on the stage host, from the repo root:
#
#   NODE=1 bash scripts/resync-validator.sh
#
# Made for a validator that sits on a private fork. A node authors at its slot without asking whether
# it is behind, and it cannot switch chains. Stage node1 was stuck at block 144,507 from 2026-10-23, was
# restarted by the deploy of 2026-10-29, made blocks of its own on that old head, and from then on
# refused every real block ("Invalid block: The previous hash should be ..."). Restarting such a node
# changes nothing (restart-validator.sh does that); its database has to go.
#
# STAGE ONLY, and node 1 or 2. There is no CHAIN switch on purpose: mainnet holds CLT, and nothing here
# is built or tested for it. Node 3 is refused: the Hub API, the explorer and the treasury read it.
#
# Before anything is touched, all of this must hold:
#   1. The OTHER two validators run and agree on one height and hash.
#   2. The target runs and its head can be read, and it is NOT a block of the chain those two hold: the
#      block at its height has another hash on them. A node that is only behind has the same blocks and
#      needs time or a restart; wiping it would throw hours away. A node at the same head has nothing
#      to fix.
#   3. The volume to delete is the one mounted at /app/data in the target's container, and it is named
#      clutch-stage_node<N>-data. There is room for a copy of it.
# Then: stop the target, copy its data to backups/stage-node<N>-data-<time>/data.tgz, remove the
# container and the volume, start the target on an empty volume. It waits only until the sync has
# visibly started (a minute or two), not until it ends. The sync pulls 100 blocks every 10 seconds, so
# 160,000 blocks take about 4.5 hours. While the node is below the blocks of an old authority set, its
# own key is not allowed to author (clutch-node previous_authorities), so it cannot fork itself again.
#
# Never `down`, never `-v` on the project, and the other two validators are never touched.
set -euo pipefail
cd "${REPO_DIR:-$(dirname "$0")/..}"

NODE="${NODE:?set NODE=1 or 2}"
# How long the other two get to agree, and how long the wiped node gets to show that it syncs.
AGREE_WAIT_SECS="${AGREE_WAIT_SECS:-120}"
START_WAIT_SECS="${START_WAIT_SECS:-180}"
case "$NODE" in
  1|2) ;;
  3)
    echo "node3 is the node the Hub API, the explorer and the treasury read: wiping it would show them a chain at block 0. Point them at another node first." >&2
    exit 2 ;;
  *) echo "NODE must be 1 or 2" >&2; exit 2 ;;
esac

PROJECT=clutch-stage
C="docker compose -p $PROJECT --env-file .env.testnet -f docker-compose.yml -f docker-compose.stage.cloudflare-flex.yml"
NET=clutch-stage_clutch-network
CURL_IMAGE=curlimages/curl:8.10.1
PY_IMAGE=python:3-alpine
# Already on this host (the treasury databases run on it) and it has tar, so nothing is pulled.
TAR_IMAGE=postgres:16-alpine
# What a wiped node must not say. "Invalid block: The block index should be" is not here on purpose: a
# repeated batch of the sync says it, and it is harmless. A previous-hash mismatch is not.
REFUSED='author verification failed|genesis hash mismatch|previous hash should be'

svc()     { echo "node$1"; }
metrics() { echo "http://node$1:300$1/metrics"; }
ws_url()  { echo "ws://node$1:808$1/ws"; }

say() { printf '\n=== %s ===\n' "$1"; }
die() { printf '::error::%s\n' "$1"; exit 1; }

# "<height> <hash>" from a node's metrics, or nothing.
head_of() {
  docker run --rm --network "$NET" "$CURL_IMAGE" -fsS --max-time 5 "$(metrics "$1")" 2>/dev/null \
    | sed -n 's/^latest_block{block_hash="\([^"]*\)"} \(.*\)$/\2 \1/p' \
    | awk 'NF==2 {printf "%d %s\n", $1, $2; exit}'
}

# The hash of a node's block at a height, or nothing. The first "hash" in the reply is the block's own:
# the transactions come after it, and "previous_hash" does not match the quoted name.
block_hash_at() {  # block_hash_at <node> <height>
  docker run --rm --network "$NET" -v "$PWD/scripts:/s:ro" "$PY_IMAGE" \
    python3 /s/node-rpc.py "$(ws_url "$1")" get_block_by_index "{\"index\":$2}" 2>/dev/null \
    | tail -1 | grep -o '"hash":"[^"]*"' | head -1 | cut -d'"' -f4 || true
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
for i in "$A" "$B"; do [ -n "$(container "$i")" ] || die "$(svc "$i") is not running; not touching $(svc "$NODE")"; done

# 1. The other two must be one chain, or there would be nothing to sync from.
deadline=$(( $(date +%s) + AGREE_WAIT_SECS ))
while :; do
  ha=$(head_of "$A" || true); hb=$(head_of "$B" || true)
  [ -n "$ha" ] && [ "$ha" = "$hb" ] && break
  [ "$(date +%s)" -lt "$deadline" ] || die "$(svc "$A") (${ha:-?}) and $(svc "$B") (${hb:-?}) do not agree; not starting"
  sleep 5
done
echo "$(svc "$A") and $(svc "$B") agree at $ha"

# 2. The target is on a different chain from theirs.
hn=$(head_of "$NODE" || true)
[ -n "$hn" ] || die "cannot read the head of $(svc "$NODE") (is it running?): not wiping a node whose chain cannot be compared"
height=${hn%% *}; hash=${hn#* }
echo "$(svc "$NODE") is at $height ($hash)"
[ "$height" -le "${ha%% *}" ] || die "$(svc "$NODE") is AHEAD of the other two; not wiping it"
if [ "$hn" = "$ha" ]; then
  echo "::notice title=nothing to do::$(svc "$NODE") already holds the same head as the other two ($ha)"
  exit 0
fi
ref=$(block_hash_at "$A" "$height")
[ -n "$ref" ] || die "could not read block $height from $(svc "$A") to compare; not wiping"
if [ "$ref" = "$hash" ]; then
  die "$(svc "$NODE") holds block $height of the real chain: it is only behind, not forked. A wipe would throw its blocks away for nothing. Restart it (Restart one validator) and give it time."
fi
echo "fork confirmed: block $height is $hash on $(svc "$NODE") and $ref on $(svc "$A")"

# 3. The volume, and room for a copy.
cid=$(container "$NODE")
vol=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Name}}{{end}}{{end}}' "$cid")
[ "$vol" = "${PROJECT}_node${NODE}-data" ] \
  || die "the volume mounted at /app/data in $(svc "$NODE") is '${vol:-none}', not ${PROJECT}_node${NODE}-data: this is not the layout this script expects. Refusing."
# `docker run -v name:` CREATES a volume that does not exist, and an empty copy would pass for a backup.
docker volume inspect "$vol" >/dev/null 2>&1 || die "no volume $vol."
kb=$(docker run --rm -v "$vol:/d:ro" --entrypoint du "$TAR_IMAGE" -sk /d | awk '{print $1}')
case "$kb" in ''|*[!0-9]*) die "could not size $vol." ;; esac
mkdir -p backups
free_kb=$(df -Pk backups | awk 'NR==2 {print $4}')
echo "$vol: ${kb} KB, free on the disk: ${free_kb} KB"
[ "$free_kb" -gt $((kb * 2 + 1048576)) ] || die "less than twice the copy plus 1 GB is free."
sa=$(started_at "$A"); sb=$(started_at "$B")

say "stopping $(svc "$NODE") and copying its data"
BK="backups/stage-node${NODE}-data-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 700 "$BK"
# From here on a failure leaves a half-done wipe, and the operator needs to know where the copy is.
trap 'rc=$?; [ "$rc" -eq 0 ] || echo "::warning::stopped part-way (exit $rc). The old data of '"$(svc "$NODE")"' is in '"$BK"'/data.tgz. Check docker ps -a and docker volume ls."' EXIT
$C stop "$(svc "$NODE")"
docker run --rm -v "$vol:/d:ro" -v "$PWD/$BK:/b" --entrypoint tar "$TAR_IMAGE" czf /b/data.tgz -C /d .
gzip -t "$BK/data.tgz"
[ -s "$BK/data.tgz" ] || die "the copy of $(svc "$NODE") is empty."
cat > "$BK/README" <<EOF
The data of stage $(svc "$NODE"), copied on $(date -u +%Y-%m-%dT%H:%M:%SZ) just before it was wiped.
It was at block $height ($hash) while the other two held $ha, and block $height on them is $ref:
a private fork. data.tgz is the content of the volume $vol. It is only of use to look at the fork.
Delete this folder once the node has synced.
EOF
ls -l "$BK"

say "removing the container and the volume"
$C rm -sf "$(svc "$NODE")"
docker volume rm "$vol"

say "starting $(svc "$NODE") on an empty volume"
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
$C up -d --no-deps "$(svc "$NODE")"

say "waiting for the sync to start (up to ${START_WAIT_SECS}s)"
deadline=$(( $(date +%s) + START_WAIT_SECS ))
while :; do
  n=$(head_of "$NODE" || true)
  if [ -n "$n" ] && [ "${n%% *}" -ge 100 ]; then
    echo "$(svc "$NODE") is at ${n%% *} and climbing"
    break
  fi
  [ "$(date +%s)" -lt "$deadline" ] || die "$(svc "$NODE") did not start syncing in ${START_WAIT_SECS}s (head ${n:-unreadable}): docker logs $(container "$NODE")"
  sleep 10
done

say "checks"
c=$(docker logs --since "$started" "$(container "$NODE")" 2>&1 | grep -acE "$REFUSED" || true)
echo "$(svc "$NODE"): ${c:-0} refused block(s) since the start"
[ "${c:-0}" -eq 0 ] || die "$(svc "$NODE") refuses blocks it syncs: docker logs --since $started $(container "$NODE") | grep -E '$REFUSED'. If the image or the config lacks previous_authorities, that is why."
[ "$(started_at "$A")" = "$sa" ] || die "$(svc "$A") was restarted during this run"
[ "$(started_at "$B")" = "$sb" ] || die "$(svc "$B") was restarted during this run"
echo "$(svc "$A") and $(svc "$B") were not touched"

say "after"
for i in 1 2 3; do describe "$i"; done
echo "::notice title=resync started::$(svc "$NODE") syncs from an empty database. About 160,000 blocks at 100 per 10 seconds take around 4.5 hours. Watch it with Inspect stage (probe chain): its height should climb to the others'. The old data is in $BK/data.tgz."
