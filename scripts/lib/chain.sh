#!/usr/bin/env bash
#
# Which treasury stack a script or a workflow acts on: CHAIN=stage (the default; the testnet) or
# CHAIN=mainnet. Source it, then call chain_select:
#
#   . "$(dirname "$0")/lib/chain.sh"
#   chain_select "${CHAIN:-stage}" || exit 1
#
# chain_select sets, and only sets, these variables:
#
#   CH_NAME          stage | mainnet
#   CH_ENV_FILE      the env file that stack reads: .env | .env.mainnet
#   CH_PROJECT       the compose project
#   CH_SVC_TREASURY  the compose service names of the three app services
#   CH_SVC_SIGNER
#   CH_SVC_ORCH
#   CH_TREASURY      the containers: the three app services, then their two databases
#   CH_SIGNER
#   CH_ORCH
#   CH_TREASURY_PG
#   CH_ORCH_PG
#   CH_BACKUP_DIR    where this stack's database dumps are written
#
# The stage names are the ones the operator scripts hardcoded before this file existed. The mainnet
# names are the ones docker-compose.mainnet.treasury.yml produces, and the two stacks never share a
# container name or an app service name (see that file on why). test-chain.sh pins all of it.

chain_select() {
  case "${1:-stage}" in
    stage)
      CH_NAME=stage
      CH_ENV_FILE=.env
      CH_PROJECT=clutch-stage
      CH_SVC_TREASURY=treasury-service
      CH_SVC_SIGNER=tron-signer
      CH_SVC_ORCH=payment-orchestrator
      CH_TREASURY=clutch-stage-treasury-service-1
      CH_SIGNER=clutch-stage-tron-signer-1
      CH_ORCH=clutch-stage-payment-orchestrator-1
      CH_TREASURY_PG=clutch-stage-treasury-postgres-1
      CH_ORCH_PG=clutch-stage-orchestrator-postgres-1
      CH_BACKUP_DIR=backups
      ;;
    mainnet)
      CH_NAME=mainnet
      CH_ENV_FILE=.env.mainnet
      CH_PROJECT=clutch-main-treasury
      CH_SVC_TREASURY=mainnet-treasury-service
      CH_SVC_SIGNER=mainnet-tron-signer
      CH_SVC_ORCH=mainnet-payment-orchestrator
      CH_TREASURY=clutch-main-treasury-mainnet-treasury-service-1
      CH_SIGNER=clutch-main-treasury-mainnet-tron-signer-1
      CH_ORCH=clutch-main-treasury-mainnet-payment-orchestrator-1
      CH_TREASURY_PG=clutch-main-treasury-treasury-postgres-1
      CH_ORCH_PG=clutch-main-treasury-orchestrator-postgres-1
      CH_BACKUP_DIR=backups/mainnet
      ;;
    *)
      echo "ABORT: CHAIN must be stage or mainnet, got '${1}'." >&2
      # A refusal leaves no earlier chain's names behind, so nothing after it can act on them.
      unset CH_NAME CH_ENV_FILE CH_PROJECT CH_SVC_TREASURY CH_SVC_SIGNER CH_SVC_ORCH \
        CH_TREASURY CH_SIGNER CH_ORCH CH_TREASURY_PG CH_ORCH_PG CH_BACKUP_DIR
      return 1
      ;;
  esac
}

# The arguments `docker compose` takes for the selected stack, one per line so a path with a space
# cannot split. Stage is the four files its deploy uses; mainnet is its one file and its own env file,
# which is what keeps its secrets apart from the testnet's.
chain_compose_args() {
  if [ "$CH_NAME" = mainnet ]; then
    printf '%s\n' -p "$CH_PROJECT" --env-file "$CH_ENV_FILE" -f docker-compose.mainnet.treasury.yml
  else
    printf '%s\n' -p "$CH_PROJECT" -f docker-compose.yml -f docker-compose.treasury.yml \
      -f docker-compose.stage.cloudflare-flex.yml -f docker-compose.stage.treasury.yml
  fi
}

# chain_compose <docker compose arguments>: docker compose for the selected stack.
chain_compose() {
  [ -n "${CH_NAME:-}" ] || { echo "ABORT: call chain_select before chain_compose." >&2; return 1; }
  local args=() a
  while IFS= read -r a; do args+=("$a"); done < <(chain_compose_args)
  docker compose "${args[@]}" "$@"
}

# mainnet_backup_remote <stage's BACKUP_REMOTE>: where the mainnet dumps go when the operator has no
# remote of their own -- the same rclone remote as stage, in a folder named mainnet. Prints it.
# Prints nothing and returns 1 when it cannot be derived safely: an empty value, a remote root
# (`name:`, which has no folder to add to), or a character outside what the env file takes as a plain
# value (a space, a quote that is not the surrounding pair, `$`, a backtick).
mainnet_backup_remote() {
  local s="$1"
  s="${s#\"}"; s="${s%\"}"; s="${s%/}"
  case "$s" in
    ''|*:|*[!A-Za-z0-9_./:@+=-]*) return 1 ;;
  esac
  printf '%s/mainnet\n' "$s"
}

# chain_mask <value>: a user's address or hash, for a line of output. The logs of the workflows that run
# these scripts are public. On mainnet the value is cut to its first eight and last four characters (a
# value of 14 or fewer is not shown at all); on stage, where the money is test money, it is shown whole.
# Call it after chain_select.
chain_mask() {
  local v="$1"
  if [ "${CH_NAME:-}" != mainnet ]; then
    printf '%s' "$v"
  elif [ "${#v}" -gt 14 ]; then
    printf '%s...%s' "${v:0:8}" "${v: -4}"
  else
    printf '<hidden>'
  fi
}

# chain_mask_sql <column expression>: the same cut for a SQL select list, so that a query that shows a
# user's address never hands the whole of it to the log on mainnet. On stage the expression is unchanged.
chain_mask_sql() {
  if [ "${CH_NAME:-}" = mainnet ]; then
    printf "(left(%s, 8) || '...' || right(%s, 4))" "$1" "$1"
  else
    printf '%s' "$1"
  fi
}
