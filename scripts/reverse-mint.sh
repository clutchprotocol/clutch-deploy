#!/usr/bin/env bash
#
# Record that a mint the ledger holds was destroyed on chain.
#
#   INTENT_ID=<uuid> REASON="..." bash scripts/reverse-mint.sh
#
# Appends one mint_reversed event, which the ledger_balances view subtracts from liability. It does
# NOT touch the original mint_executed row -- treasury_events is append-only, and the original is a
# true record of something that did happen. The pair reads as "recorded, then lost".
#
# No USDT moves and no payout is owed. If a payout IS owed, this is the wrong tool: that is a
# redemption (burn_redeemed).

set -euo pipefail

INTENT_ID="${INTENT_ID:?INTENT_ID must be set}"
REASON="${REASON:?REASON must be set — it lands in the event description and is the only record of why}"

# Container name copied from inspect-stage.sh, not guessed -- the first version of this script
# invented clutch-stage-treasury-db-1, which does not exist.
PSQL="docker exec -i clutch-stage-treasury-postgres-1 psql -U treasury -d treasury -t -A"

# The intent must exist and be one the ledger actually counted. Reversing a 'created' intent would
# subtract liability that was never added.
ROW=$($PSQL -c "SELECT status, amount_clt FROM mint_intents WHERE id = '$INTENT_ID'")
if [ -z "$ROW" ]; then
  echo "ABORT: no intent $INTENT_ID."
  exit 1
fi
STATUS="${ROW%%|*}"
AMOUNT="${ROW##*|}"
case "$STATUS" in
  credited|submitted) ;;
  *) echo "ABORT: intent is '$STATUS'. Only a credited or submitted mint is counted in liability; reversing anything else subtracts what was never added."; exit 1;;
esac

# Must have a mint_executed to reverse. A submitted-but-not-yet-credited intent counts as in-flight
# instead, and in-flight clears itself when the intent resolves -- reversing it double-subtracts.
HAS_EXEC=$($PSQL -c "SELECT count(*) FROM treasury_events WHERE intent_id = '$INTENT_ID' AND kind = 'mint_executed'")
if [ "$HAS_EXEC" != "1" ]; then
  echo "ABORT: intent $INTENT_ID has no mint_executed event (found $HAS_EXEC)."
  echo "  Nothing was added to liability for it, so there is nothing to reverse."
  exit 1
fi

BEFORE=$($PSQL -c "SELECT clt_liability FROM ledger_balances")
echo "=== before ==="
echo "    intent:    $INTENT_ID ($STATUS, $AMOUNT CLT)"
echo "    liability: $BEFORE"

$PSQL -c "INSERT INTO treasury_events (kind, amount_clt, intent_id, description)
          VALUES ('mint_reversed', $AMOUNT, '$INTENT_ID', \$\$$REASON\$\$)" >/dev/null

AFTER=$($PSQL -c "SELECT clt_liability FROM ledger_balances")
echo ""
echo "=== after ==="
echo "    liability: $AFTER"

# Verify the arithmetic rather than trusting the insert. A view definition that did not pick up
# mint_reversed would leave liability unchanged and this would say so.
EXPECTED=$((BEFORE - AMOUNT))
if [ "$AFTER" != "$EXPECTED" ]; then
  echo ""
  echo "ABORT: liability is $AFTER, expected $EXPECTED ($BEFORE - $AMOUNT)."
  echo "  The event was appended but the view did not subtract it — migration 0007 may not have run."
  exit 1
fi

echo ""
echo "liability reduced by $AMOUNT. The breaker does NOT clear itself — reconciliation must run and"
echo "agree, then an Approver releases it via resume-minting."
