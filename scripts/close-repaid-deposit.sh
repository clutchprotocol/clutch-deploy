#!/usr/bin/env bash
#
# Close a `needs_manual` deposit that a human has already made good, by hand.
#
#   DEPOSIT_ID=2ad18204-... bash scripts/close-repaid-deposit.sh
#
# When a deposit's mint intent fails, its client_ref is burned and the deposit parks in
# `needs_manual`. Repaying the depositor therefore means a BRAND-NEW treasury mint intent to the
# same beneficiary -- and nothing links that new intent back to the deposit row, so the deposit
# sits in `needs_manual` forever even though the person has their CLT.
#
# That is not harmless. "Needs review" is the one number on the dashboard that means real money is
# waiting on somebody, and a permanently non-zero one is an alert people learn to ignore.
#
# The guard is what makes this safe: it refuses unless the treasury already holds a CREDITED mint
# intent for that deposit's beneficiary. It cannot be used to make an unpaid deposit look paid --
# only to record a repayment that demonstrably happened.

set -euo pipefail

DEPOSIT_ID="${DEPOSIT_ID:?DEPOSIT_ID must be set (the orchestrator deposit_intents id)}"

OPG=clutch-stage-orchestrator-postgres-1
TPG=clutch-stage-treasury-postgres-1

for c in "$OPG" "$TPG"; do
  if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then
    echo "ABORT: container $c is not running."
    exit 1
  fi
done

# The dashboard and the probe show a short id, so accept a prefix -- but resolve it to exactly one
# row and refuse if it matches more than one. Guessing which of two money rows was meant is not a
# thing this script gets to do.
MATCHES=$(docker exec "$OPG" psql -U orchestrator -d orchestrator -tAc   "select id from deposit_intents where id::text like '$DEPOSIT_ID%';" 2>/dev/null | tr -d '')
COUNT=$(printf '%s
' "$MATCHES" | grep -c . || true)
case "$COUNT" in
  0) echo "ABORT: no deposit whose id starts with '$DEPOSIT_ID'."; exit 1;;
  1) DEPOSIT_ID=$(printf '%s' "$MATCHES" | tr -d '[:space:]'); echo "resolved to $DEPOSIT_ID";;
  *) echo "ABORT: '$DEPOSIT_ID' matches $COUNT deposits:"; printf '%s
' "$MATCHES" | sed 's/^/    /'; exit 1;;
esac

echo "=== the deposit ==="
docker exec "$OPG" psql -U orchestrator -d orchestrator -c \
  "select id, status, amount_usdt, received_usdt, clt_address, tron_tx_id, created_at
     from deposit_intents where id = '$DEPOSIT_ID';" 2>&1 | sed 's/^/    /'

STATUS=$(docker exec "$OPG" psql -U orchestrator -d orchestrator -tAc \
  "select status from deposit_intents where id = '$DEPOSIT_ID';" 2>/dev/null | tr -d '[:space:]')
BENEFICIARY=$(docker exec "$OPG" psql -U orchestrator -d orchestrator -tAc \
  "select clt_address from deposit_intents where id = '$DEPOSIT_ID';" 2>/dev/null | tr -d '[:space:]')

if [ -z "$STATUS" ]; then
  echo "ABORT: no deposit with id $DEPOSIT_ID."
  exit 1
fi
if [ "$STATUS" != "needs_manual" ]; then
  echo "ABORT: deposit is '$STATUS'. This closes needs_manual rows only, and nothing else."
  exit 1
fi

echo ""
echo "=== the evidence: credited mints to this beneficiary ==="
docker exec "$TPG" psql -U treasury -d treasury -c \
  "select id, amount_clt, status, created_at from mint_intents
    where beneficiary = '$BENEFICIARY' order by created_at;" 2>&1 | sed 's/^/    /'

PAID=$(docker exec "$TPG" psql -U treasury -d treasury -tAc \
  "select count(*) from mint_intents
    where beneficiary = '$BENEFICIARY' and status = 'credited';" 2>/dev/null | tr -d '[:space:]')

case "$PAID" in
  ''|0)
    echo ""
    echo "ABORT: no credited mint exists for $BENEFICIARY."
    echo "  This deposit has NOT been made good, so closing it would hide someone who is owed CLT."
    echo "  Repay them first with mint-intent-create.yml + mint-intent-approve.yml, then run this."
    exit 1;;
esac

echo ""
echo "=== closing ==="
echo "    $PAID credited mint(s) to $BENEFICIARY — the depositor has been made good."
docker exec "$OPG" psql -U orchestrator -d orchestrator -c \
  "update deposit_intents set status = 'credited', updated_at = now()
    where id = '$DEPOSIT_ID' and status = 'needs_manual';" 2>&1 | sed 's/^/    /'

echo ""
echo "closed. The deposit reads 'credited' because the depositor was credited — by a separate"
echo "intent, which is the only way a burned client_ref can be repaid. Nothing was minted here."
