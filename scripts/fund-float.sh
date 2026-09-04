#!/usr/bin/env bash
#
# Move the fee account's misplaced USDT into the payout float.
#
#   bash scripts/fund-float.sh
#
# The fee account at <account>/1/0 exists to pay TRX energy. USDT there is misplaced by definition
# -- nothing in this stack ever intends to put it there -- and because reserve is custody plus
# unswept deposits plus the float, USDT sitting in the fee account is counted in NO bucket. Real
# treasury money, outside the accounting.
#
# This asks tron-signer to move ALL of it to the payout float at <account>/2/0, which redemptions
# pay out from. The endpoint takes no parameters at all: source, destination, amount and token are
# fixed, and both addresses are derived by the signer from its own mnemonic rather than read from
# config. There is nothing here for a caller to redirect -- which is why this script passes no
# arguments either, and why it must never grow any.
#
# THE RESERVE RISES, AND THAT IS ALL. `custody_reported` -- the reserve read from chain, which is
# custody plus unswept deposits plus the float -- goes up by the amount moved, while the ledger's
# figures do not change at all. Reconciliation uses that number in exactly one comparison,
# `custody_reported < ledger_liability -> mismatch`, so a BIGGER reserve only makes a mismatch less
# likely. The run should stay `ok`.
#
# It does NOT cause over_backed_drift. That status compares on-chain SUPPLY against ledger
# liability and means the ledger counts CLT issued that does not exist on chain -- someone owed
# money they do not hold. If you see it after this, it is unrelated to the float and worth reading
# properly rather than waving away.

set -euo pipefail

SIGNER=clutch-stage-tron-signer-1

if ! docker ps --format '{{.Names}}' | grep -qx "$SIGNER"; then
  echo "ABORT: container $SIGNER is not running."
  exit 1
fi

echo "=== the two addresses, from the signer itself ==="
docker exec "$SIGNER" sh -c \
  "curl -fsS -H \"Authorization: Bearer \$APP_SIGNER_TOKEN\" http://localhost:8093/internal/xpub" \
  2>/dev/null | sed 's/,/,\n    /g' | sed 's/^/    /' || echo "    (could not read /internal/xpub)"

echo ""
echo "=== moving the fee account's USDT to the payout float ==="
echo "    (no parameters: both ends are derived by the signer, not passed in)"

RESP=$(docker exec "$SIGNER" sh -c \
  "curl -fsS -X POST -H \"Authorization: Bearer \$APP_SIGNER_TOKEN\" -H 'Content-Type: application/json' \
        http://localhost:8093/internal/fund-float") || {
  echo "ABORT: the signer refused or was unreachable."
  echo "  A 500 here means the failure may have followed a real broadcast -- read the fee account's"
  echo "  outbound transfers on chain before running this again."
  exit 1
}

echo "    $RESP"
echo ""

case "$RESP" in
  *'"status":"funded"'*)
    echo "moved. The USDT is in the payout float and redemptions can be paid from it."
    echo "NOTE: the chain-read reserve rises by this amount and the ledger does not move, which"
    echo "      only makes a reserve-below-liability mismatch LESS likely. The next"
    echo "      reconciliation should still read ok."
    ;;
  *'"status":"nothing_to_move"'*)
    echo "nothing to move: the fee account holds no USDT. Already moved, or never misplaced any."
    echo "No USDT moved and no transaction was broadcast."
    ;;
  *'"status":"fee_account_dry"'*)
    echo "ABORT-ish: the fee account cannot pay TRX for its own transfer. Top it up, then re-run."
    echo "  Nothing moved. Note this account funds every sweep too, so it being dry stops those as well."
    exit 1
    ;;
  *'"status":"refused"'*)
    echo "refused before broadcasting anything -- see the reason above. Safe to re-run once fixed."
    exit 1
    ;;
  *)
    echo "unrecognised response. Nothing is assumed; read tron-signer's logs and the chain before"
    echo "re-running, because an unknown answer is not proof that nothing was broadcast."
    exit 1
    ;;
esac
