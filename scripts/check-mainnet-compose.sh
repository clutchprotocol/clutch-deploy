#!/usr/bin/env bash
#
# The mainnet treasury's compose file against the stage stack's: names that would collide, ports,
# networks and drift. CI runs it on the two rendered configs (check-monitoring-config.yml):
#
#   docker compose --env-file stage.env -f docker-compose.yml -f docker-compose.treasury.yml config --format json > stage.json
#   docker compose --env-file mainnet.env -f docker-compose.mainnet.treasury.yml config --format json > mainnet.json
#   bash scripts/check-mainnet-compose.sh stage.json mainnet.json
#
# Why it exists. Compose gives every container its service name as a DNS alias on every network it
# joins, and an `aliases:` entry only adds to that. Prometheus and nginx sit on networks both stacks
# would join, so a second `treasury-service` or `payment-orchestrator` there is two containers
# answering to one name: scrapes and proxied requests reach either stack at random, and the mainnet
# orchestrator can call the TESTNET treasury. The mainnet file therefore has its own names, and is a
# copy of the money path; this is what keeps the copy from drifting from the original.
#
# It reads JSON only: no docker, no network, no .env.

set -uo pipefail

STAGE="${1:?usage: check-mainnet-compose.sh <stage.json> <mainnet.json>}"
MAIN="${2:?usage: check-mainnet-compose.sh <stage.json> <mainnet.json>}"

fail=0
ok()  { printf 'OK    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=1; }

# The three app services: stage name, then the mainnet name.
PAIRS="treasury-service:mainnet-treasury-service tron-signer:mainnet-tron-signer payment-orchestrator:mainnet-payment-orchestrator"
MAINNET_USDT=TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t

names() { jq -r '.services | keys[]' "$1" | sort; }

# Services that touch a network that is not private to their own project. A private network is
# `internal: true`: its name is project-scoped, so the same service name in the other stack is a
# different container on a different network and cannot collide. A service answers to its key, to each
# of its `aliases:` on the network and to its `container_name`, so all of those are printed.
on_shared_network() {
  jq -r '. as $r | .services | to_entries[] | .key as $s | .value as $v
         | (.value.networks // {} | to_entries[]) as $n
         | select(($r.networks[$n.key].internal // false) | not)
         | $s, ($n.value.aliases // [])[], ($v.container_name // empty)' "$1" | sort -u
}

# 1. A mainnet service on a shared network may not carry a name the stage stack also uses. A stage file
#    with no services would make this pass by default, so that is refused first.
if [ -z "$(names "$STAGE")" ]; then bad "the stage file has no services"; fi
shared=$(comm -12 <(names "$STAGE") <(on_shared_network "$MAIN") | tr '\n' ' ')
if [ -z "$shared" ]; then
  ok "no service name is shared with the stage stack"
else
  bad "service names shared with the stage stack: ${shared% }"
fi

# 2. No mainnet service publishes a port.
published=$(jq -r '.services | to_entries[] | select((.value.ports // []) | length > 0) | .key' "$MAIN" | tr '\n' ' ')
if [ -z "$published" ]; then ok "no mainnet service publishes a port"; else bad "services that publish a port: ${published% }"; fi

# 3. Only the orchestrator joins a stage network, because nginx lives there and resolves upstreams by
#    container name. It may do so only under its own name (check 1) and only with its pilot allowlist set
#    (APP_PILOT_ALLOWED_ADDRESSES, which compose requires, so a render without it never gets here). The
#    treasury service and the signer never join: the signer holds the mnemonic.
ORCH=mainnet-payment-orchestrator
onstage=$(jq -r '. as $r | .services | to_entries[] | .key as $s
                 | (.value.networks // {} | keys[]) as $n
                 | select(($r.networks[$n].name // $n) | startswith("clutch-stage")) | $s' "$MAIN" | sort -u)
others=$(printf '%s\n' "$onstage" | grep -v -x -e '' -e "$ORCH" | tr '\n' ' ') || true
if [ -z "$others" ]; then
  ok "no mainnet service but the orchestrator joins a stage network"
else
  bad "services on a stage network: ${others% }"
fi
if printf '%s\n' "$onstage" | grep -qx "$ORCH"; then
  if [ -n "$(jq -r --arg m "$ORCH" '.services[$m].environment.APP_PILOT_ALLOWED_ADDRESSES // ""' "$MAIN")" ]; then
    ok "$ORCH is on a stage network with its pilot allowlist set"
  else
    bad "$ORCH is on a stage network without APP_PILOT_ALLOWED_ADDRESSES"
  fi
fi

# 4. Every setting a stage service has, its mainnet twin has too (it may have more). A stage service
#    with no settings (renamed, or missing from the render) would make this pass by default.
for p in $PAIRS; do
  s="${p%%:*}" m="${p##*:}"
  if ! jq -e --arg s "$s" '(.services[$s].environment // {}) | length > 0' "$STAGE" >/dev/null; then
    bad "stage has no $s to compare with"
    continue
  fi
  missing=$(comm -23 \
    <(jq -r --arg s "$s" '.services[$s].environment // {} | keys[]' "$STAGE" | sort) \
    <(jq -r --arg m "$m" '.services[$m].environment // {} | keys[]' "$MAIN" | sort) | tr '\n' ' ')
  if [ -z "$missing" ]; then
    ok "$m has every setting $s has"
  else
    bad "$m lacks the stage settings: ${missing% }"
  fi
done

# 5. No mainnet setting names a stage host.
stagehosts=$(jq -r '.services | to_entries[] | .key as $s | (.value.environment // {} | to_entries[])
                    | select(.value | tostring | test("//(treasury-service|tron-signer|payment-orchestrator)([:/]|$)"))
                    | "\($s).\(.key)"' "$MAIN" | tr '\n' ' ')
if [ -z "$stagehosts" ]; then ok "no mainnet setting names a stage host"; else bad "mainnet settings that name a stage host: ${stagehosts% }"; fi

# 6. Each of the three images is its own service's, pinned to a sha tag: seven lower-case hex characters.
image_of() {  # image_of <mainnet service>: the name of its image under ghcr.io/clutchprotocol/
  case "$1" in
    mainnet-treasury-service)     echo clutch-treasury ;;
    mainnet-tron-signer)          echo clutch-tron-signer ;;
    mainnet-payment-orchestrator) echo clutch-orchestrator ;;
  esac
}
unpinned=""
for p in $PAIRS; do
  m="${p##*:}"
  image=$(jq -r --arg m "$m" '.services[$m].image // ""' "$MAIN")
  re="^ghcr\.io/clutchprotocol/$(image_of "$m"):sha-[0-9a-f]{7}\$"
  [[ $image =~ $re ]] || unpinned="$unpinned $m"
done
if [ -z "$unpinned" ]; then ok "the three images are pinned to a sha tag"; else bad "not pinned to a sha tag:$unpinned"; fi

# 7. What makes it mainnet.
env_of() { jq -r --arg m "$1" --arg k "$2" '.services[$m].environment[$k] // ""' "$MAIN"; }
T=mainnet-treasury-service
[ "$(env_of $T APP_CHAIN_ID)" = "1000" ] && ok "$T runs chain 1000" || bad "$T must run chain 1000"
[ "$(env_of $T APP_SIGNER_KIND)" = "env" ] && ok "$T signs with the mint key on this host (env)" || bad "$T must sign with the env signer"
# The env signer panics at start when this is empty; compose requires it, so a render without it never
# gets here, and an empty one would mean a mint key that is not there.
[ -n "$(env_of $T APP_MINT_AUTHORITY_SECRET)" ] && ok "$T has an APP_MINT_AUTHORITY_SECRET" || bad "$T must have an APP_MINT_AUTHORITY_SECRET"
case "$(env_of $T APP_NODE_WS_URL)" in
  ws://mainnet-node*) ok "$T reads a mainnet node" ;;
  *) bad "$T must read a mainnet node" ;;
esac
# The nodes it checks the chain against: the list must be set, and every entry a mainnet node. (An
# empty string splits into no entries in jq, so the length is tested first.)
if jq -e --arg m "$T" '(.services[$m].environment.APP_NODE_PEER_WS_URLS // "")
                       | length > 0 and (split(",") | all(startswith("ws://mainnet-node")))' "$MAIN" >/dev/null; then
  ok "$T reads mainnet peers"
else
  bad "$T must read mainnet peers"
fi
for p in $PAIRS; do
  m="${p##*:}"
  [ "$(env_of "$m" APP_TRONGRID_URL)" = "https://api.trongrid.io" ] \
    && ok "$m uses TronGrid mainnet" || bad "$m must use TronGrid mainnet"
  [ "$(env_of "$m" APP_USDT_CONTRACT)" = "$MAINNET_USDT" ] \
    && ok "$m watches the mainnet USDT contract" || bad "$m must watch the mainnet USDT contract"
done

exit "$fail"
