#!/usr/bin/env bash
# Restart the validators of one chain, ONE AT A TIME, onto the image and node config that main now
# pins. Run on the stage host, from the repo root, after `git pull`:
#
#   CHAIN=stage   bash scripts/upgrade-validators.sh
#   CHAIN=mainnet bash scripts/upgrade-validators.sh
#
# Made for a rule that switches on at a FUTURE block (clutch-node `wallet_transfers_from_block`):
# below that block the new build and the old one accept exactly the same blocks, so the set can be
# restarted one node at a time while the other two keep authoring. The script refuses when the
# switch block is too close for that to be true. It is NOT for a change that takes effect at once,
# such as a new authorities list: that is a coordinated restart (docs/AUTHORITY-ROTATION.md).
#
# After each node it waits until all three report the same height and block hash, reads that
# node's log for refused blocks, and asks it to admit a wallet transfer signed by a throwaway key
# that never holds CLT. A node that loaded the rule refuses it for the reason the rule gives
# ("starts at block N" below the switch, "insufficient balance" from it on); one that did not says
# "not enabled". Nothing is ever admitted. Any failed check stops the run with the remaining
# validators untouched.
#
# Never `down`, never `-v`: the chain is in the volumes.
set -euo pipefail
# REPO_DIR: the workflow ships this file from its own checkout and runs it against the host's.
cd "${REPO_DIR:-$(dirname "$0")/..}"

CHAIN="${CHAIN:?set CHAIN=stage or CHAIN=mainnet}"
# Blocks that must remain before the switch when the run starts. Three restarts take a few minutes
# and a block comes every 20 seconds; 90 blocks is half an hour.
MARGIN="${MARGIN:-90}"
PY_IMAGE=python:3-alpine
CURL_IMAGE=curlimages/curl:8.10.1

case "$CHAIN" in
  stage)
    C="docker compose -p clutch-stage --env-file .env.testnet -f docker-compose.yml -f docker-compose.stage.cloudflare-flex.yml"
    NET=clutch-stage_clutch-network
    CONF=config/node
    svc()     { echo "node$1"; }
    ws_url()  { echo "ws://node$1:808$1/ws"; }
    metrics() { echo "http://node$1:300$1/metrics"; }
    # Signed by ethers 6.13.4 with the key 0x77..77 (address 0xae72a48c1a36bd18af168541c53037965d26e4a8),
    # chain id 20771, nonce 0, 0.000001 CLT to 0x...dead, 48 gwei x 21000.
    PROBE_TX=0xf86b80850b2d05e00082520894000000000000000000000000000000000000dead85e8d4a510008082a26aa07004f2d87c1c35635dcdc218b1bc2dd196b784fd20eb32a1157379a005335dfca0434f63561adcf63838917545f8a9b958e3e82f8f703107deef5bbc304edc91c0
    ;;
  mainnet)
    C="docker compose -p clutch-main --env-file .env.mainnet -f docker-compose.mainnet.yml"
    NET=clutch-mainnet
    CONF=config/node-mainnet
    svc()     { echo "mainnet-node$1"; }
    ws_url()  { echo "ws://mainnet-node$1:818$1/ws"; }
    metrics() { echo "http://mainnet-node$1:310$1/metrics"; }
    # The same key and transfer, signed for chain id 20770.
    PROBE_TX=0xf86b80850b2d05e00082520894000000000000000000000000000000000000dead85e8d4a510008082a268a03fd2e5ed2f6dcee4c16018a4aafd9158c478a2f896a1be47d00d7fec4d4ac441a03666025c712de2d75d989526bf1f0c711c50ad22f35c4098688d6381bc9cb0d8
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

rpc() {
  docker run --rm --network "$NET" -v "$PWD/scripts:/s:ro" "$PY_IMAGE" \
    python3 /s/node-rpc.py "$(ws_url "$1")" "$2" "$3" 2>&1 | tail -1
}

container() { echo "$($C ps -q "$(svc "$1")" 2>/dev/null)"; }

describe() {
  local id; id=$(container "$1")
  [ -n "$id" ] || { echo "$(svc "$1"): not running"; return; }
  echo "$(svc "$1"): $(docker inspect -f '{{.Config.Image}} started {{.State.StartedAt}}' "$id") head $(head_of "$1" || echo '?')"
}

# All three at one height with one hash. Blocks keep coming, so retry for up to five minutes.
wait_for_agreement() {
  local deadline=$(( $(date +%s) + 300 )) a b c
  while [ "$(date +%s)" -lt "$deadline" ]; do
    a=$(head_of 1 || true); b=$(head_of 2 || true); c=$(head_of 3 || true)
    if [ -n "$a" ] && [ "$a" = "$b" ] && [ "$b" = "$c" ]; then
      echo "all three at $a"
      return 0
    fi
    sleep 5
  done
  printf 'node1: %s\nnode2: %s\nnode3: %s\n' "${a:-?}" "${b:-?}" "${c:-?}"
  return 1
}

say "what main pins for $CHAIN"
git log -1 --oneline
image=$($C config --images 2>/dev/null | grep '/clutch-node:' | sort -u)
[ "$(echo "$image" | wc -l)" -eq 1 ] || die "the three validators do not pin one image: $image"
echo "image: $image"

say "the wallet transfer switch in $CONF"
# Every validator must carry the same two values, or one of them refuses blocks the others accept.
switch=""
for i in 1 2 3; do
  f="$CONF/node$i.toml"
  id=$(sed -n 's/^wallet_chain_id *= *\([0-9]*\).*/\1/p' "$f")
  from=$(sed -n 's/^wallet_transfers_from_block *= *\([0-9]*\).*/\1/p' "$f")
  [ -n "$id" ] && [ -n "$from" ] || die "$f: set both wallet_chain_id and wallet_transfers_from_block"
  echo "node$i: wallet_chain_id=$id wallet_transfers_from_block=$from"
  [ -z "$switch" ] || [ "$switch" = "$id $from" ] || die "the three configs disagree on the switch"
  switch="$id $from"
done
FROM_BLOCK=${switch#* }

say "before"
for i in 1 2 3; do describe "$i"; done
wait_for_agreement || die "the validators do not agree before anything was touched; not starting"
height=$(head_of 1 | cut -d' ' -f1)

# The switch must still be ahead, with room for three restarts, unless every validator already
# runs this image (a re-run, or a chain like stage that switched on at genesis with this build).
pending=0
for i in 1 2 3; do
  id=$(container "$i")
  [ -n "$id" ] && [ "$(docker inspect -f '{{.Config.Image}}' "$id")" = "$image" ] || pending=1
done
if [ "$pending" -eq 1 ] && [ "$FROM_BLOCK" -gt 0 ] && [ $(( FROM_BLOCK - height )) -lt "$MARGIN" ]; then
  die "the switch is at block $FROM_BLOCK and the chain is at $height: fewer than $MARGIN blocks left to restart three validators one at a time. Move the switch later."
fi
echo "::notice title=before::chain at $height, switch at $FROM_BLOCK, image $image"

say "pulling $image"
$C pull -q "$(svc 1)" "$(svc 2)" "$(svc 3)"

for i in 1 2 3; do
  say "restarting $(svc "$i")"
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  $C up -d --no-deps --force-recreate "$(svc "$i")"
  describe "$i"

  wait_for_agreement || die "$(svc "$i") did not rejoin the other two within five minutes. $(svc $(( i % 3 + 1 ))) and the third are untouched by this run."

  # A rejoining node logs "Failed to add block" for gossip that arrives while it catches up, so
  # that line alone means nothing. These mean a node disagrees with a block the others accepted.
  # Read all three: a peer refusing the restarted node's blocks shows only in the peer's log.
  for j in 1 2 3; do
    n=$(docker logs --since "$started" "$(container "$j")" 2>&1 | grep -acE "$DISAGREE" || true)
    echo "$(svc "$j"): ${n:-0} refused block(s) since the restart"
    [ "${n:-0}" -eq 0 ] || die "$(svc "$j") refuses blocks: docker logs --since $started $(container "$j") | grep -E '$DISAGREE'"
  done

  answer=$(rpc "$i" send_wallet_transaction "\"$PROBE_TX\"")
  echo "probe: $answer"
  case "$answer" in
    *"starts at block $FROM_BLOCK"*|*"insufficient balance"*) echo "the wallet transfer rule is loaded" ;;
    *) die "$(svc "$i") did not answer the probe with the rule's refusal" ;;
  esac
  case "$answer" in *'"result"'*) die "$(svc "$i") ADMITTED the probe transaction" ;; esac
  echo "::notice title=$(svc "$i")::$(describe "$i"); rule loaded"
done

say "after"
for i in 1 2 3; do describe "$i"; done
echo "::notice title=done::All three validators run $image with the wallet transfer switch at block $FROM_BLOCK."
