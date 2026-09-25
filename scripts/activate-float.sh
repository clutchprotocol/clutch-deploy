#!/usr/bin/env bash
#
# Activate the GasFree payout float, once, from the reserve's surplus (GasFree design §4).
#
#   bash scripts/activate-float.sh
#
# The float's first outgoing transfer also pays for deploying its contract, up to ACTIVATE + TRANSFER.
# A redemption's fee covers only TRANSFER, so a redemption making that first transfer would leave the
# reserve below supply. So the first transfer is this one: the smallest amount the relay accepts, from
# the float to custody, paid for by the surplus the treasury already holds. Users are charged the
# configured maxima, and the difference stays behind as backing — that is what pays for this.
#
# It runs one reconciliation itself, then refuses unless that run is `ok`, under two hours old, and
# shows
#
#   custody_reported - ledger_liability - owed >= activate max + transfer max
#
# where `owed` is what redemptions burned and not yet paid took off the liability: a burn lowers
# ledger_liability at once, and its USDT stays in the float until the payout confirms. Without it,
# a redemption waiting for this activation would be counted as surplus that pays for it.
#
# The maxima are read from the RUNNING signer: the values that size the permit's maxFee. Custody
# gains the amount moved; the reserve loses only the relay's fee, which the surplus covers.
#
# The endpoint takes no parameters — the float, custody, the amount and the fee cap are all the
# signer's own — and this script passes none. It must never grow any.

set -euo pipefail

SIGNER=clutch-stage-tron-signer-1
PG=clutch-stage-treasury-postgres-1
TREASURY=clutch-stage-treasury-service-1

# Whether the surplus pays for the activation. Pure, so test-activate-float.sh can run it.
#
#   can_activate <status> <age seconds> <custody_reported> <ledger_liability> <owed> <activate max> <transfer max>
can_activate() {
  local status="$1" age="$2" reserve="$3" liability="$4" owed="$5" act="$6" xfer="$7" v
  for v in "$act" "$xfer"; do
    case "$v" in
      ''|*[!0-9]*)
        echo "the running signer has no GasFree maxima (APP_GASFREE_*_FEE_MAX_USDT): GasFree is off in tron-signer"
        return 1 ;;
    esac
  done
  if [ "$status" != "ok" ]; then
    echo "the latest reconciliation run is '$status', not ok"
    return 1
  fi
  for v in "$age" "$reserve" "$liability" "$owed"; do
    case "$v" in
      ''|*[!0-9-]*)
        echo "the latest reconciliation run is unreadable: '$v'"
        return 1 ;;
    esac
  done
  if [ "$age" -gt 7200 ]; then
    echo "the latest reconciliation run is ${age}s old, so the run above did not finish; read its output, then run this again"
    return 1
  fi
  local surplus=$((reserve - liability - owed)) need=$((act + xfer))
  echo "the surplus is $surplus micro-USDT; activation may cost up to $need (after $owed micro-USDT owed to redemptions not yet paid)"
  [ "$surplus" -ge "$need" ]
}

main() {
  local c run status age reserve liability owed act xfer msg resp
  for c in "$PG" "$SIGNER" "$TREASURY"; do
    if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then
      echo "ABORT: container $c is not running."
      exit 1
    fi
  done

  echo "=== the float, from the signer itself ==="
  docker exec "$SIGNER" sh -c \
    "curl -fsS -H \"Authorization: Bearer \$APP_SIGNER_TOKEN\" http://localhost:8093/internal/xpub" \
    2>/dev/null | sed 's/,/,\n    /g' | sed 's/^/    /' || echo "    (could not read /internal/xpub)"

  echo ""
  echo "=== does the surplus pay for the activation? ==="
  # One reconciliation first, so the decision below reads a run taken now, not up to an hour ago.
  # --reconcile-once prints the status and exits: it starts no worker and moves nothing
  # (clutch-treasury's treasury-service main.rs). A failed run changes nothing here: the check
  # below then reads an older run and refuses.
  docker exec "$TREASURY" treasury-service --reconcile-once 2>&1 | tail -3 | sed 's/^/    /' || true
  # A burn lowers ledger_liability at once, but its USDT stays in the float until the payout
  # confirms, so a redemption not yet paid would count as surplus. Its whole amount_clt, not the
  # payout: that is the most it takes out of the reserve (the payout, plus a relay fee its redemption
  # fee covers). The same statuses as clutch_treasury_oldest_unpaid_redemption_seconds.
  run=$(docker exec "$PG" psql -U treasury -d treasury -tA -F ' ' -c \
    "select status, extract(epoch from now() - run_at)::bigint, custody_reported, ledger_liability,
            (select coalesce(sum(amount_clt), 0)::bigint from redemption_intents
              where status in ('burn_confirmed', 'payout_pending', 'payout_submitted'))
       from reconciliation_runs order by run_at desc limit 1;" 2>/dev/null || true)
  read -r status age reserve liability owed <<< "$run" || true
  act=$(docker exec "$SIGNER" printenv APP_GASFREE_ACTIVATE_FEE_MAX_USDT 2>/dev/null || true)
  xfer=$(docker exec "$SIGNER" printenv APP_GASFREE_TRANSFER_FEE_MAX_USDT 2>/dev/null || true)
  if msg=$(can_activate "${status:-none}" "${age:-}" "${reserve:-}" "${liability:-}" "${owed:-}" "$act" "$xfer"); then
    echo "    $msg"
  else
    echo "ABORT: $msg. Nothing was signed."
    exit 1
  fi

  echo ""
  echo "=== activating the GasFree float ==="
  echo "    (no parameters: the float, custody, the amount and the fee cap are the signer's own)"
  resp=$(docker exec "$SIGNER" sh -c \
    "curl -fsS -X POST -H \"Authorization: Bearer \$APP_SIGNER_TOKEN\" -H 'Content-Type: application/json' \
          http://localhost:8093/internal/activate-float") || {
    echo "ABORT: the signer refused or was unreachable."
    echo "  A 500 may follow a real submission: read the float's outbound transfers on chain before"
    echo "  running this again."
    exit 1
  }
  echo "    $resp"
  echo ""
  case "$resp" in
    *'"status":"submitted"'*)
      echo "submitted. The float is activated once this permit runs, usually within a minute; PROBE=gasfree"
      echo "then shows it activated, and redemptions stop answering 'not available yet'. The next"
      echo "reconciliation run shows the surplus lower by the relay's fee, and nothing else."
      ;;
    *'"status":"already_active"'*)
      echo "already activated. Nothing was signed."
      ;;
    *'"status":"float_dry"'*)
      echo "the float cannot pay for its own activation yet. It fills from GasFree sweeps while it holds"
      echo "less than PAYOUT_FLOAT_TARGET_USDT: run this again after a deposit is swept. Nothing was signed."
      exit 1
      ;;
    *'"status":"refused"'*)
      echo "refused before anything was signed -- see the reason above."
      exit 1
      ;;
    *)
      echo "unrecognised response. Nothing is assumed: read tron-signer's logs and the float's transfers"
      echo "on chain before running this again."
      exit 1
      ;;
  esac
}

# Sourced by test-activate-float.sh for can_activate; run, it activates.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
