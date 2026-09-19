#!/usr/bin/env bash
# Start the Clutch MAINNET validators. Run on the stage host, from the repo root.
#
# THIS IS THE IRREVERSIBLE ONE. The moment the first block is authored, all eleven genesis values
# are fixed: chain_id, is_testnet, tx_fee, both referrer rates, mint_authority, faucet_address,
# faucet_allocation, mint_cosigners, mint_threshold and ride_auto_release_secs. Peers compare the
# genesis hash at handshake, so changing any of them afterwards is a new chain from block zero, not
# a configuration change.
#
# Every gate below exists to be the last chance to catch something before that becomes true. None
# of them is a formality; each one has a matching way to be wrong that is cheap now and permanent
# in ten minutes.
#
# NEVER run `down -v` against this project. On the testnet that is a reset. Here it is the loss of
# the chain, and there is no second copy.
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT=clutch-main
COMPOSE="docker compose -p ${PROJECT} -f docker-compose.mainnet.yml"
NET=clutch-mainnet
CURL_IMAGE=curlimages/curl:8.10.1

say()  { printf '\n=== %s ===\n' "$1"; }
die()  { printf 'ABORT: %s\n' "$1" >&2; exit 1; }

say "what this host is about to start"
git log -1 --oneline || true
[ -d config/node-mainnet ] || die "config/node-mainnet is missing — the host has not pulled it"

say "the genesis values being committed, permanently"
grep -hE '^(chain_id|is_testnet|tx_fee|mint_authority|faucet_address|faucet_allocation|ride_request_referrer_fee_bps|ride_offer_referrer_fee_bps|ride_auto_release_secs) ' \
  config/node-mainnet/node1.toml
printf '\nauthorities:\n'
sed -n '/^authorities = \[/,/^\]/p' config/node-mainnet/node1.toml

say "check-genesis, with the mainnet rules"
# The real gate. It compares every committed field across all three configs and applies the
# mainnet-only rules. A disagreement of one character means the nodes cannot peer.
CONFIG_DIR=config/node-mainnet MAINNET=1 bash scripts/check-genesis.sh

say "validator secrets"
[ -f .env ] || die "no .env on this host"
missing=""
for i in 1 2 3; do
  if ! grep -q "^MAINNET_NODE${i}_AUTHOR_SECRET=" .env; then missing="$missing node${i}"; fi
done
[ -z "$missing" ] || die "the .env is missing validator secrets for:$missing — run the keygen workflow"
echo "all three present (values not printed)"

say "is a mainnet chain already running?"
# Refuse rather than recreate. If containers exist, a chain may already have blocks, and
# `up -d --force-recreate` on a live chain is a restart nobody asked for.
existing=$(docker ps -a --filter "label=com.docker.compose.project=${PROJECT}" --format '{{.Names}}' || true)
if [ -n "$existing" ]; then
  echo "$existing"
  die "the ${PROJECT} project already has containers. This script only starts a chain that does not exist yet."
fi
echo "none — this is a first start"

say "starting three validators"
$COMPOSE up -d
$COMPOSE ps

say "waiting for the first blocks"
# Three authorities own 20-second slots (60 / len), so a couple of blocks takes about a minute.
head_of() {
  docker run --rm --network "$NET" "$CURL_IMAGE" -fsS --max-time 5 \
    "http://mainnet-node$1:310$1/metrics" 2>/dev/null \
    | sed -n 's/^latest_block{block_hash="\([^"]*\)"} \(.*\)$/\2 \1/p' \
    | awk 'NF==2 {printf "%d %s\n", $1, $2; exit}'
}

deadline=$(( $(date +%s) + 300 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  h1=$(head_of 1 || true)
  if [ -n "$h1" ] && [ "${h1%% *}" -ge 2 ]; then break; fi
  sleep 10
done
[ -n "${h1:-}" ] || die "no node reported a block within 5 minutes — check '$COMPOSE logs'"

say "do all three agree?"
sleep 25
for i in 1 2 3; do printf 'node%s: %s\n' "$i" "$(head_of "$i" || echo '<no answer>')"; done

a=$(head_of 1 || true); b=$(head_of 2 || true); c=$(head_of 3 || true)
for v in "$a" "$b" "$c"; do
  [ -n "$v" ] || die "a node is not answering — the set is not healthy, check the logs before trusting this chain"
done
# Equal heights are not agreement; a node whose authorities list differs keeps pace on its own
# chain and says so only in its log. Compare the block, and read the logs too.
say "is any node rejecting blocks?"
rej=0
for i in 1 2 3; do
  n=$($COMPOSE logs "mainnet-node${i}" 2>/dev/null | grep -ac 'author verification failed' || true)
  printf 'node%s: %s rejection(s)\n' "$i" "${n:-0}"
  [ "${n:-0}" -eq 0 ] || rej=1
done
[ "$rej" -eq 0 ] || die "a node is refusing blocks the others accept — compare the authorities lists"

say "done"
echo "The mainnet chain is running and its genesis is now permanent."
echo "mint_authority: $(grep -E '^mint_authority ' config/node-mainnet/node1.toml)"
echo "Never run 'down -v' against project ${PROJECT}."
