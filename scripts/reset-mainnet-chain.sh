#!/usr/bin/env bash
#
# Replace the mainnet chain with a new, empty one. Run from the repo root on the stage host, by
# "Mainnet - reset the chain (once)". It only STOPS and WIPES the old chain. The new one is started
# afterwards by "Mainnet - start the chain" (START MAINNET), which already holds every genesis gate.
#
#   MODE=check bash scripts/reset-mainnet-chain.sh    read-only: the gates, nothing is changed
#   MODE=reset bash scripts/reset-mainnet-chain.sh    the gates, then halt, stop, copy, wipe
#
# Why this exists. mint_authority is one of the genesis values, so it cannot change on a running
# chain. Moving the mint key from Azure KMS to this host (readiness A1, "Mint key on the host",
# accepted 2026-10-05) therefore needs a new chain. start-mainnet.sh says never to run `down -v` on
# this project, and that is right for a chain that holds anything. This is the one exception, and it
# is allowed only because every gate below proves the old chain holds nothing: no CLT was ever minted
# on it, so nobody owns anything on it and nothing is lost by wiping it.
#
# The gates, all read-only, in order. Any one that fails stops the script before anything changes:
#   1. .env.mainnet has the new mint key and its address, and all three node configs have that address
#      as mint_authority. check-genesis.sh (the mainnet rules) passes on them. Starting the new chain
#      would otherwise fail AFTER the old one is gone.
#   2. The mainnet treasury still signs with Azure KMS. That is true before the cutover and false after,
#      so a second run of this script refuses.
#   3. The treasury ledger shows no mint, and the last reconciliation shows zero supply on chain.
#   4. There is room for a copy of the three data volumes.
# After the gates, "reset" mode: halts minting (so nothing is signed while the chain is down), stops
# the project, copies the three volumes into backups/mainnet-chain-<time>/ and checks the copies, then
# runs `down -v`.

set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${MODE:?MODE must be check or reset}"
case "$MODE" in check|reset) ;; *) echo "ABORT: MODE must be check or reset, got '$MODE'."; exit 1 ;; esac

PROJECT=clutch-main
COMPOSE="docker compose -p ${PROJECT} -f docker-compose.mainnet.yml"
NET=clutch-mainnet
CURL_IMAGE=curlimages/curl:8.10.1
# Already on this host (the treasury databases run on it) and it has tar, so nothing is pulled.
TAR_IMAGE=postgres:16-alpine

say() { printf '\n=== %s ===\n' "$1"; }
die() { printf 'ABORT: %s\n' "$1" >&2; exit 1; }

. "$(dirname "$0")/lib/chain.sh"
chain_select mainnet

say "1. the new mint key and the node configs"
[ -f .env.mainnet ] || die "no .env.mainnet here ($(pwd))."
secret=$(sed -n 's/^MINT_AUTHORITY_SECRET=//p' .env.mainnet | head -1)
address=$(sed -n 's/^MINT_AUTHORITY_ADDRESS=//p' .env.mainnet | head -1)
printf '%s' "$secret" | grep -Eq '^[0-9a-f]{64}$' \
  || die "MINT_AUTHORITY_SECRET in .env.mainnet is not a 64-character hex key. Run \"Mainnet - create the mint key\"."
printf '%s' "$address" | grep -Eq '^0x[0-9a-f]{40}$' \
  || die "MINT_AUTHORITY_ADDRESS in .env.mainnet is missing or not an address."
for i in 1 2 3; do
  got=$(sed -n 's/^mint_authority = "\(0x[0-9a-fA-F]\{40\}\)".*/\1/p' "config/node-mainnet/node${i}.toml" | head -1 | tr 'A-F' 'a-f')
  [ "$got" = "$address" ] \
    || die "config/node-mainnet/node${i}.toml has a mint_authority that is not MINT_AUTHORITY_ADDRESS. Has this host pulled the change that sets it?"
done
echo "OK: all three node configs name the mint address of the key in .env.mainnet (the address is public: $address)"
CONFIG_DIR=config/node-mainnet MAINNET=1 bash scripts/check-genesis.sh

say "2. the treasury still signs with the old key"
# Read off the container's configuration, not its environment as a whole: that holds secrets.
kind=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CH_TREASURY" 2>/dev/null \
         | sed -n 's/^APP_SIGNER_KIND=//p' | head -1) || true
echo "APP_SIGNER_KIND of $CH_TREASURY: ${kind:-<no such container>}"
[ "$kind" = azure_kms ] \
  || die "the mainnet treasury does not sign with azure_kms. Either the cutover is already done, or this is not the host this script expects. Refusing."

say "3. nothing was ever minted on the old chain"
sql() { docker exec "$CH_TREASURY_PG" psql -U treasury -d treasury -tAc "$1" | tr -d '[:space:]'; }
minted=$(sql "select count(*) from treasury_events where kind = 'mint_executed'") || die "could not read the treasury database."
live=$(sql "select count(*) from mint_intents where status in ('approved','submitted','credited')") || die "could not read the treasury database."
supply=$(sql "select coalesce((select onchain_supply from reconciliation_runs order by id desc limit 1), 0)") || die "could not read the treasury database."
echo "mint events in the ledger:                          $minted"
echo "mint intents approved, submitted or credited:       $live"
echo "supply on chain at the last reconciliation (micro): $supply"
for v in "$minted" "$live" "$supply"; do
  case "$v" in ''|*[!0-9]*) die "a number above is not a number. Nothing is assumed." ;; esac
done
[ "$minted" -eq 0 ] && [ "$live" -eq 0 ] && [ "$supply" -eq 0 ] \
  || die "CLT exists, or may exist, on the old chain. Wiping it would lose what people own. Refusing."
echo "OK: the old chain holds nothing."

say "4. room for a copy of the old chain"
need_kb=0
for n in 1 2 3; do
  vol="${PROJECT}_mainnet-node${n}-data"
  # `docker run -v name:` CREATES a volume that does not exist, and an empty copy would pass for a backup.
  docker volume inspect "$vol" >/dev/null 2>&1 || die "no volume $vol: this is not the layout this script expects."
  kb=$(docker run --rm -v "$vol:/d:ro" --entrypoint du "$TAR_IMAGE" -sk /d | awk '{print $1}')
  case "$kb" in ''|*[!0-9]*) die "could not size $vol." ;; esac
  echo "$vol: ${kb} KB"
  need_kb=$((need_kb + kb))
done
mkdir -p backups
free_kb=$(df -Pk backups | awk 'NR==2 {print $4}')
echo "to copy: ${need_kb} KB, free on the disk: ${free_kb} KB"
[ "$free_kb" -gt $((need_kb * 2 + 1048576)) ] || die "less than twice the copy plus 1 GB is free."
for n in 1 2 3; do
  out=$(docker run --rm --network "$NET" "$CURL_IMAGE" -fsS --max-time 5 "http://mainnet-node${n}:310${n}/metrics" 2>/dev/null || true)
  echo "mainnet-node${n} height: $(printf '%s\n' "$out" | grep -aE '^latest_block_index' | awk '{print $2}' | head -1)"
done

if [ "$MODE" = check ]; then
  say "check only"
  echo "Every gate passed. Nothing was changed."
  exit 0
fi

say "5. halt minting"
CHAIN=mainnet REASON="mainnet chain reset: the mint key moves to this host" bash scripts/halt-minting.sh

say "6. stop the mainnet chain and copy its data"
BK="backups/mainnet-chain-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 700 "$BK"
$COMPOSE stop
for n in 1 2 3; do
  docker run --rm -v "${PROJECT}_mainnet-node${n}-data:/d:ro" -v "$PWD/$BK:/b" --entrypoint tar "$TAR_IMAGE" \
    czf "/b/node${n}.tgz" -C /d .
  gzip -t "$BK/node${n}.tgz"
  [ -s "$BK/node${n}.tgz" ] || die "the copy of node ${n} is empty."
done
cat > "$BK/README" <<EOF
The old mainnet chain (chain_id 1000), copied on $(date -u +%Y-%m-%dT%H:%M:%SZ) just before it was wiped.
Its mint_authority was 0xe44cda17f55acf4ccc03cab374de1f227cac6621, an Azure Key Vault key.
No CLT had been minted on it. node1.tgz, node2.tgz and node3.tgz are the three data volumes.
It is only of use for a rollback, which also needs that Azure key and the compose files of before the cutover.
Delete this folder once the new chain has run for a while.
EOF
ls -l "$BK"

say "7. delete the old chain"
$COMPOSE down -v
left=$(docker ps -a --filter "label=com.docker.compose.project=${PROJECT}" --format '{{.Names}}' || true)
[ -z "$left" ] || die "containers of ${PROJECT} remain: $left"
vols=$(docker volume ls -q --filter "name=${PROJECT}_mainnet-node" || true)
[ -z "$vols" ] || die "volumes remain: $vols"

say "done"
echo "The old chain is gone. A copy is in $BK."
echo "Next, in this order: \"Mainnet - start the chain\" (START MAINNET), \"Mainnet - start the treasury\","
echo "then \"Resume minting\" for mainnet."
