#!/usr/bin/env bash
# Put a stuck `submitted` mint back in the outbox queue, so it is rebuilt and submitted again.
#
# WHY THIS EXISTS. `submitted` is terminal in practice. The outbox retries `pending` and `failed`;
# nothing re-drives `submitted`, nothing times it out, and nothing checks whether the transaction
# ever landed. Only the watcher writes `confirmed`, so a submission that died — a nonce already
# consumed, a chain reset underneath it, a reorg — leaves a row that waits for ever while
# reconciliation reports the amount as under-issuance, also for ever. That is CLT a depositor paid
# for and never received.
#
# WHY IT CANNOT DOUBLE-MINT. `mint_intents.credit_ref` is UNIQUE, and the chain stores
# `processed_ref_<credit_ref>` as an exactly-once marker shared by Mint and Burn. If the original
# transaction actually did land, the marker is already there and the resubmission is rejected by
# `verify_state`. The worst case of re-driving a mint that succeeded is a wasted transaction, not
# duplicate CLT. That property is what makes this safe to automate rather than a four-eyes ritual.
#
# It still refuses to touch anything that is not stuck: only a `submitted` outbox row is eligible.
# A `pending` row is already queued, a `confirmed` one is done, and a `failed` one is a different
# decision that should be made deliberately.
#
# Usage:  INTENT_ID=<uuid> bash scripts/redrive-mint.sh

set -euo pipefail

cd "$(dirname "$0")/.."

INTENT_ID="${INTENT_ID:-}"
if [ -z "$INTENT_ID" ]; then
  echo "ABORT: INTENT_ID is not set."
  exit 1
fi
# Validated here as well as in the workflow, because a workflow input is not a trusted string and
# this one is interpolated into SQL.
if ! printf '%s' "$INTENT_ID" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
  echo "ABORT: INTENT_ID is not a UUID: $INTENT_ID"
  exit 1
fi

env_get() {
  # `|| true`: an absent key is an empty answer, not a failure. Under `set -euo pipefail` a grep
  # matching nothing kills the script inside a command substitution, with no output.
  grep -E "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' || true
}

PGPASS="$(env_get TREASURY_POSTGRES_PASSWORD)"
CONTAINER="${TREASURY_CONTAINER:-clutch-stage-treasury-postgres-1}"

psql_t() {
  docker exec -e "PGPASSWORD=$PGPASS" -i "$CONTAINER" psql -U treasury -d treasury -v ON_ERROR_STOP=1 "$@"
}

echo "=== before ==="
psql_t -c "
  select o.id as outbox_id, o.status as outbox_status, o.attempts, o.next_attempt_at,
         i.status as intent_status, i.amount_clt, i.beneficiary,
         left(i.chain_tx_hash, 18) as tx_hash
  from chain_outbox o join mint_intents i on i.id = o.intent_id
  where o.intent_id = '$INTENT_ID';"

ELIGIBLE="$(psql_t -tAc "
  select count(*) from chain_outbox
  where intent_id = '$INTENT_ID' and status = 'submitted';" | tr -d '[:space:]')"

if [ "$ELIGIBLE" != "1" ]; then
  echo ""
  echo "ABORT: no outbox row for that intent is in 'submitted'."
  echo "  Only a stuck submission is re-drivable. 'pending' is already queued, 'confirmed' is done,"
  echo "  and 'failed' is a different decision to make deliberately."
  exit 1
fi

echo ""
echo "=== re-driving ==="
# attempts reset to 0 as well: the retry budget should count attempts at THIS submission, and the
# old count belongs to a transaction built for a chain state that no longer exists.
psql_t -c "
  update chain_outbox
     set status = 'pending', attempts = 0, next_attempt_at = now(), last_error = NULL
   where intent_id = '$INTENT_ID' and status = 'submitted';"

echo ""
echo "=== after ==="
psql_t -c "
  select o.id as outbox_id, o.status as outbox_status, o.attempts, o.next_attempt_at,
         i.status as intent_status
  from chain_outbox o join mint_intents i on i.id = o.intent_id
  where o.intent_id = '$INTENT_ID';"

echo ""
echo "The outbox polls every 2 seconds, so this should move to 'submitted' almost immediately and"
echo "to 'confirmed' once the watcher sees it on chain — which requires the watcher's cursor to be"
echo "at or below the chain head. Check with:"
echo "    PROBE=sweeper  ->  '=== watcher chain cursor ==='"
echo ""
echo "Reconciliation clears on its next run. Until then the p1 for this amount is still correct."
