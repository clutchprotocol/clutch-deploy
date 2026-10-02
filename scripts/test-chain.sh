#!/usr/bin/env bash
# Self-check for scripts/lib/chain.sh: the container, service, project and file names each chain
# resolves to. The stage names are the ones the operator scripts hardcoded before the helper existed;
# the mainnet names are the ones docker-compose.mainnet.treasury.yml produces, and two cases tie them to
# the compose files so a rename in one place fails here. CI runs it (test-treasury-scripts.yml); it
# needs no docker.
set -euo pipefail
cd "$(dirname "$0")/.."

passed=0
failed=0

# check <name> <wanted> <got>
check() {
  if [ "$2" = "$3" ]; then
    passed=$((passed + 1))
    echo "ok    $1"
  else
    failed=$((failed + 1))
    echo "FAIL  $1"
    printf '        wanted: %s\n        got:    %s\n' "$2" "$3"
  fi
}

# Every variable chain_select sets, on one line. A refused chain prints REFUSED.
names_of() {
  (
    . scripts/lib/chain.sh
    chain_select "$1" >/dev/null 2>&1 || { echo REFUSED; exit 0; }
    echo "$CH_NAME|$CH_ENV_FILE|$CH_PROJECT|$CH_SVC_TREASURY|$CH_SVC_SIGNER|$CH_SVC_ORCH|$CH_TREASURY|$CH_SIGNER|$CH_ORCH|$CH_TREASURY_PG|$CH_ORCH_PG|$CH_BACKUP_DIR"
  )
}
containers_of() {
  (
    . scripts/lib/chain.sh
    chain_select "$1" >/dev/null
    printf '%s\n' "$CH_TREASURY" "$CH_SIGNER" "$CH_ORCH" "$CH_TREASURY_PG" "$CH_ORCH_PG"
  )
}
derived_of() {
  (
    . scripts/lib/chain.sh
    chain_select "$1" >/dev/null
    echo "$CH_PROJECT-$CH_SVC_TREASURY-1 $CH_PROJECT-$CH_SVC_SIGNER-1 $CH_PROJECT-$CH_SVC_ORCH-1"
  )
}
actual_of() {
  (
    . scripts/lib/chain.sh
    chain_select "$1" >/dev/null
    echo "$CH_TREASURY $CH_SIGNER $CH_ORCH"
  )
}
args_of() {
  (
    . scripts/lib/chain.sh
    chain_select "$1" >/dev/null
    chain_compose_args | tr '\n' ' '
  )
}
# A refused chain must return, not exit: the caller decides what to do next.
refusal_survived() {
  (
    . scripts/lib/chain.sh
    chain_select testnet 2>/dev/null || true
    echo survived
  )
}
# chain_compose against a stub docker that prints each argument it gets, followed by |.
compose_of() {
  (
    . scripts/lib/chain.sh
    chain_select "$1" >/dev/null
    docker() { printf '%s|' "$@"; }
    chain_compose up -d x
  )
}
compose_unselected() {
  (
    . scripts/lib/chain.sh
    docker() { printf '%s|' "$@"; }
    chain_compose up -d x 2>/dev/null || echo refused
  )
}
# What all twelve CH_* names hold after a good chain_select and then a refused one: they are printed
# one after the other, so any name that was left behind shows between the brackets.
name_after_refusal() {
  (
    . scripts/lib/chain.sh
    chain_select mainnet >/dev/null
    chain_select testnet 2>/dev/null || true
    echo "[${CH_NAME:-}${CH_ENV_FILE:-}${CH_PROJECT:-}${CH_SVC_TREASURY:-}${CH_SVC_SIGNER:-}${CH_SVC_ORCH:-}${CH_TREASURY:-}${CH_SIGNER:-}${CH_ORCH:-}${CH_TREASURY_PG:-}${CH_ORCH_PG:-}${CH_BACKUP_DIR:-}]"
  )
}
# The files after -f in the compose arguments that are not in the repository root (the working directory).
missing_files_of() {
  (
    . scripts/lib/chain.sh
    chain_select "$1" >/dev/null
    prev=""
    while IFS= read -r a; do
      if [ "$prev" = "-f" ] && [ ! -f "$a" ]; then printf ' %s' "$a"; fi
      prev="$a"
    done < <(chain_compose_args)
  )
}

STAGE="stage|.env|clutch-stage|treasury-service|tron-signer|payment-orchestrator|clutch-stage-treasury-service-1|clutch-stage-tron-signer-1|clutch-stage-payment-orchestrator-1|clutch-stage-treasury-postgres-1|clutch-stage-orchestrator-postgres-1|backups"
MAINNET="mainnet|.env.mainnet|clutch-main-treasury|mainnet-treasury-service|mainnet-tron-signer|mainnet-payment-orchestrator|clutch-main-treasury-mainnet-treasury-service-1|clutch-main-treasury-mainnet-tron-signer-1|clutch-main-treasury-mainnet-payment-orchestrator-1|clutch-main-treasury-treasury-postgres-1|clutch-main-treasury-orchestrator-postgres-1|backups/mainnet"

check "stage: the names the scripts used to hardcode" "$STAGE" "$(names_of stage)"
check "stage is the default" "$STAGE" "$(names_of '')"
check "mainnet: the names docker-compose.mainnet.treasury.yml produces" "$MAINNET" "$(names_of mainnet)"
check "an unknown chain is refused" "REFUSED" "$(names_of testnet)"
check "stage container names are <project>-<service>-1" "$(derived_of stage)" "$(actual_of stage)"
check "mainnet container names are <project>-<service>-1" "$(derived_of mainnet)" "$(actual_of mainnet)"

missing=""
for s in treasury-postgres orchestrator-postgres mainnet-treasury-service mainnet-tron-signer mainnet-payment-orchestrator; do
  grep -q "^  $s:" docker-compose.mainnet.treasury.yml || missing="$missing $s"
done
check "every mainnet service is in docker-compose.mainnet.treasury.yml" "" "$missing"

missing=""
for s in treasury-postgres orchestrator-postgres treasury-service tron-signer payment-orchestrator; do
  grep -q "^  $s:" docker-compose.treasury.yml || missing="$missing $s"
done
check "every stage service is in docker-compose.treasury.yml" "" "$missing"

overlap=$(comm -12 <(containers_of stage | sort) <(containers_of mainnet | sort) | tr '\n' ' ')
check "no mainnet container name is a stage container name" "" "$overlap"

check "stage compose arguments" "-p clutch-stage -f docker-compose.yml -f docker-compose.treasury.yml -f docker-compose.stage.cloudflare-flex.yml -f docker-compose.stage.treasury.yml " "$(args_of stage)"
check "mainnet compose arguments" "-p clutch-main-treasury --env-file .env.mainnet -f docker-compose.mainnet.treasury.yml " "$(args_of mainnet)"

check "a refused chain returns instead of exiting" "survived" "$(refusal_survived)"
check "chain_compose passes the stage arguments to docker" "compose|-p|clutch-stage|-f|docker-compose.yml|-f|docker-compose.treasury.yml|-f|docker-compose.stage.cloudflare-flex.yml|-f|docker-compose.stage.treasury.yml|up|-d|x|" "$(compose_of stage)"
check "chain_compose passes the mainnet arguments to docker" "compose|-p|clutch-main-treasury|--env-file|.env.mainnet|-f|docker-compose.mainnet.treasury.yml|up|-d|x|" "$(compose_of mainnet)"
check "chain_compose without chain_select refuses" "refused" "$(compose_unselected)"
check "a refused chain_select clears the earlier names" "[]" "$(name_after_refusal)"
check "every compose file the arguments name exists" "" "$(missing_files_of stage)$(missing_files_of mainnet)"

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
