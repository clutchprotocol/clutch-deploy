#!/usr/bin/env bash
#
# Sweep ONE deposit address into custody, by hand.
#
#   ADDRESS=TRopxke7ZGs3SZWv5zMuCeqEk4y2ZkQnxh bash scripts/sweep-address.sh
#
# The automatic sweeper only collects addresses whose mint intent reached `credited` or `submitted`
# (see treasury-service/src/sweeper.rs -- it will not move evidence out from under the verifier).
# That is the right default and it leaves exactly one gap: an intent that ends `failed` keeps real
# USDT at a real address that nothing will ever collect, and a `failed` row is also dropped from
# reconciliation's reserve sum, so the money stops being counted while it is still there.
#
# This script closes that gap deliberately, one address at a time, with a reason in the workflow log
# that invoked it.
#
# It resolves the derivation index from the treasury database and hands the SIGNER an index and
# nothing else. That is not a detail: tron-signer's sweep API takes an index because the destination
# is its own config, so no caller -- including this script -- can redirect a sweep. Do not "improve"
# this by passing an address, a contract or an amount to the signer.

set -euo pipefail

ADDRESS="${ADDRESS:?ADDRESS must be set (the TRON deposit address to sweep)}"

case "$ADDRESS" in
  T*) ;;
  *) echo "ABORT: '$ADDRESS' is not a TRON base58 address (expected it to start with T)."; exit 1;;
esac

PG=clutch-stage-treasury-postgres-1
SIGNER=clutch-stage-tron-signer-1

for c in "$PG" "$SIGNER"; do
  if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then
    echo "ABORT: container $c is not running."
    exit 1
  fi
done

echo "=== what the treasury knows about this address ==="
docker exec "$PG" psql -U treasury -d treasury -c \
  "select id, status, amount_clt, derivation_index, swept_at, created_at
     from mint_intents where deposit_address = '$ADDRESS' order by created_at;" 2>&1 | sed 's/^/    /'

INDEX=$(docker exec "$PG" psql -U treasury -d treasury -tAc \
  "select derivation_index from mint_intents
    where deposit_address = '$ADDRESS' and derivation_index is not null
    order by created_at limit 1;" 2>/dev/null | tr -d '[:space:]')

case "$INDEX" in
  ''|*[!0-9]*)
    echo ""
    echo "ABORT: no derivation index recorded for $ADDRESS."
    echo "  Without one the signer cannot derive the key, and this script will not guess."
    exit 1;;
esac

echo ""
echo "=== sweeping derivation index $INDEX ==="
echo "    (destination is the signer's own custody config, not a parameter)"

RESP=$(docker exec "$SIGNER" sh -c \
  "curl -fsS -X POST -H \"Authorization: Bearer \$APP_SIGNER_TOKEN\" -H 'Content-Type: application/json' \
        -d '{\"index\": $INDEX}' http://localhost:8093/internal/sweep") || {
  echo "ABORT: the signer refused or was unreachable."
  exit 1
}

echo "    $RESP"
echo ""

case "$RESP" in
  *'"status":"swept"'*)
    # Record it. The automatic sweeper sets swept_at itself; this script did not, so an address
    # emptied by hand still read as unswept -- which kept it in the unswept-address metric and in
    # reconciliation's reserve sum while its real balance was zero. Every intent sharing this
    # address is marked: deposit addresses are permanent, so one sweep empties all of them.
    docker exec "$PG" psql -U treasury -d treasury -c       "update mint_intents set swept_at = now()
        where deposit_address = '$ADDRESS' and swept_at is null;" 2>&1 | sed 's/^/    /'
    echo "swept. The USDT is in custody; reconciliation will count it there on its next run."
    echo "NOTE: this does NOT credit anyone CLT. If the depositor is owed it, that is a separate"
    echo "      correction through mint-intent-create.yml, and it can only pass the reserve check"
    echo "      once this sweep has landed."
    ;;
  *'"status":"nothing_to_sweep"'*)
    echo "nothing to sweep: the address holds no USDT above the sweep threshold. Already collected,"
    echo "or never funded. No action taken."
    ;;
  *'"status":"funded"'*)
    echo "the address had no TRX for its own fee, so the signer funded it from the fee account."
    echo "Run this again to perform the sweep itself."
    ;;
  *'"status":"fee_account_dry"'*)
    echo "ABORT-ish: the fee account cannot pay for the sweep. Top it up (the address is above),"
    echo "then run this again. Nothing moved."
    exit 1
    ;;
  *)
    echo "unrecognised response above. Nothing is assumed; check tron-signer's logs."
    exit 1
    ;;
esac
