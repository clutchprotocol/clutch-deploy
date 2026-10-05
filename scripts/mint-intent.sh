#!/usr/bin/env bash
#
# The four-eyes mint flow, as two separate actions.
#
#   ACTION=create   BENEFICIARY=0x... AMOUNT_CLT=990000000 REASON="..."   bash scripts/mint-intent.sh
#   ACTION=approve  INTENT_ID=<uuid>                                      bash scripts/mint-intent.sh
#
# CHAIN=stage (the default) or CHAIN=mainnet picks the treasury it acts on (scripts/lib/chain.sh). The
# logs of the workflows that run this are public, so on mainnet a user's address is never printed whole.
#
# `approve` takes an intent in `created` (a manual mint, or a deposit's intent not yet approved) and in
# `needs_manual`. The second is where a deposit lands when it is over the per-transaction mint cap, and
# the way out is to raise the cap (set-mint-caps) and approve it again: the treasury's approve call
# accepts that on purpose (intents.rs), and the alert that tells the operator to do it names this tool.
#
# # What this does and does not enforce
#
# The treasury derives `created_by` and `approved_by` from the AUTHENTICATED ROLE, never from the
# request, and a DB CHECK refuses a row where the two are equal. That part is enforced in the
# database and this script cannot weaken it.
#
# What it does NOT enforce is that two different PEOPLE ran the two halves. Both tokens live in the
# same host `.env`, so anyone who can dispatch these workflows can dispatch both. The separation
# here is procedural: two dispatches, each attributed to a GitHub actor in the Actions log. Treat
# that log as the audit trail, because the database only records the role strings.
#
# Minting creates money. Nothing here should be run to "just try it".

set -euo pipefail

. "$(dirname "$0")/lib/chain.sh"
chain_select "${CHAIN:-stage}" || exit 1
PG=$CH_TREASURY_PG
SVC=$CH_TREASURY
ACTION="${ACTION:?ACTION must be create or approve}"
echo "treasury: $CH_NAME"

# Every value below that reaches SQL is checked first, because a workflow input is not a trusted string.
UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

# The treasury's reply names the beneficiary in full. On mainnet that value is cut like every other.
show_resp() {
  if [ "$CH_NAME" = mainnet ]; then
    printf '%s' "$1" | sed -E 's/("beneficiary":"[^"]{8})[^"]*([^"]{4}")/\1...\2/g'
  else
    printf '%s' "$1"
  fi
}

show_intent() {
  docker exec "$PG" psql -U treasury -d treasury \
    -c "select id, $(chain_mask_sql beneficiary) as beneficiary, amount_clt, status, created_by, approved_by, created_at
        from mint_intents where id = '$1';" 2>&1 | sed 's/^/    /'
}

if [ "$ACTION" = "create" ]; then
  BENEFICIARY="${BENEFICIARY:?BENEFICIARY must be set}"
  AMOUNT_CLT="${AMOUNT_CLT:?AMOUNT_CLT must be set}"
  REASON="${REASON:?REASON must be set — this is the only record of WHY money was created}"

  case "$AMOUNT_CLT" in
    ''|*[!0-9]*) echo "ABORT: AMOUNT_CLT must be a positive integer in micro-dollars (1 USD = 1000000)."; exit 1;;
  esac
  # BENEFICIARY is interpolated into SQL below, so only the characters of an address (or a stage
  # test name) get through. On mainnet it must be an address: 0x and 40 hex characters.
  case "$BENEFICIARY" in
    ''|*[!0-9A-Za-z_.:-]*) echo "ABORT: BENEFICIARY has a character an address does not."; exit 1;;
  esac
  if [ "$CH_NAME" = mainnet ] && ! printf '%s' "$BENEFICIARY" | grep -qE '^0x[0-9a-fA-F]{40}$'; then
    echo "ABORT: on mainnet BENEFICIARY must be 0x and 40 hex characters."
    exit 1
  fi

  # There is no idempotency key available for a manual mint: the treasury's `client_ref` requires
  # `expected_amount_usdt`, which pins the verifier to an on-chain transfer that a correction mint
  # does not have. So a re-run WOULD create a second intent and mint twice. This check is what
  # stands in for that -- refuse when an equivalent intent is already live.
  DUPES=$(docker exec "$PG" psql -U treasury -d treasury -tAc \
    "select count(*) from mint_intents
     where beneficiary = '$BENEFICIARY' and amount_clt = $AMOUNT_CLT
       and status in ('created','approved','submitted','credited');" 2>/dev/null | tr -d '[:space:]')

  # The guard assumes a `credited` intent means the CLT is on chain. A chain reset breaks that
  # assumption: stage holds an intent marked credited whose mint was destroyed, leaving a depositor
  # short. Re-issuing is then correct and the guard is wrong -- but only in that case, so the
  # override is explicit, needs its own justification, and stays off by default.
  if [ "${DUPES:-0}" != "0" ] && [ "${OVERRIDE_DUPLICATE:-false}" = "true" ]; then
    : "${OVERRIDE_REASON:?OVERRIDE_REASON must be set when overriding the duplicate guard}"
    echo "!!! DUPLICATE GUARD OVERRIDDEN — $DUPES matching intent(s) exist and are being ignored."
    echo "!!! justification: $OVERRIDE_REASON"
    echo "!!! Verify the shortfall on chain BEFORE approving:"
    if [ "$CH_NAME" = mainnet ]; then
      echo "!!!   look the beneficiary up on the mainnet explorer (the address is not printed on mainnet)"
    else
      echo "!!!   inspect-stage.yml -f probe=balance -f address=$BENEFICIARY"
    fi
    echo "!!! Approval is still a separate dispatch by a second person. Nothing is minted here."
    echo ""
    DUPES=0
  fi

  if [ "${DUPES:-0}" != "0" ]; then
    echo "ABORT: $DUPES existing intent(s) already match this beneficiary and amount:"
    docker exec "$PG" psql -U treasury -d treasury \
      -c "select id, amount_clt, status, created_at from mint_intents
          where beneficiary = '$BENEFICIARY' and amount_clt = $AMOUNT_CLT
            and status in ('created','approved','submitted','credited') order by created_at;" 2>&1 | sed 's/^/    /'
    echo "  Minting again would duplicate one of these. Approve the existing intent, or cancel it first."
    exit 1
  fi

  echo "=== creating mint intent ==="
  echo "    beneficiary: $(chain_mask "$BENEFICIARY")"
  echo "    amount_clt:  $AMOUNT_CLT  (\$$(awk "BEGIN{printf \"%.2f\", $AMOUNT_CLT/1000000}"))"
  echo "    reason:      $REASON"
  echo ""

  # Initiator token, read inside the container and never printed. No deposit fields: this is a
  # manual mint with no new on-chain transfer to verify, so an Approver must judge it rather than
  # the verifier auto-approving on evidence.
  # The payload is built here and handed over with `docker exec -e`, and the token is expanded
  # INSIDE the container. Getting this backwards is what made the first attempt 401: the header sat
  # in single quotes within the sh -c string, so the container never expanded the variable and curl
  # sent the literal text "$APP_INITIATOR_TOKEN" as the bearer token.
  PAYLOAD=$(printf '{"beneficiary":"%s","amount_clt":%s}' "$BENEFICIARY" "$AMOUNT_CLT")
  RESP=$(docker exec -e PAYLOAD="$PAYLOAD" "$SVC" sh -c \
    'curl -sS --fail-with-body -X POST -H "Authorization: Bearer $APP_INITIATOR_TOKEN" \
     -H "Content-Type: application/json" -d "$PAYLOAD" \
     http://127.0.0.1:8090/internal/mint-intents' 2>&1 || true)

  echo "    response: $(show_resp "$RESP")"
  ID=$(printf '%s' "$RESP" | sed -n 's/.*"id":"\([0-9a-f-]*\)".*/\1/p')
  if [ -z "$ID" ]; then
    echo ""
    echo "ABORT: no intent id in the response — nothing was created."
    exit 1
  fi

  echo ""
  echo "=== created ==="
  show_intent "$ID"
  echo ""
  echo "    intent id: $ID"
  echo "    NOT yet approved and nothing has been minted. A DIFFERENT person must now run"
  echo "    'Approve mint intent' with this id. Reason recorded here: $REASON"
  exit 0
fi

if [ "$ACTION" = "approve" ]; then
  INTENT_ID="${INTENT_ID:?INTENT_ID must be set}"
  if ! printf '%s' "$INTENT_ID" | grep -qE "$UUID_RE"; then
    echo "ABORT: INTENT_ID is not a UUID."
    exit 1
  fi

  echo "=== intent before approval ==="
  show_intent "$INTENT_ID"

  STATUS=$(docker exec "$PG" psql -U treasury -d treasury -tAc \
    "select status from mint_intents where id = '$INTENT_ID';" 2>/dev/null | tr -d '[:space:]')
  if [ -z "$STATUS" ]; then
    echo "ABORT: no such intent."
    exit 1
  fi
  # `needs_manual` too: see the header. An intent in any other status is already past approval or
  # terminal, and the treasury would refuse it as well.
  if [ "$STATUS" != "created" ] && [ "$STATUS" != "needs_manual" ]; then
    echo "ABORT: intent is '$STATUS', not 'created' or 'needs_manual'. Only those can be approved."
    exit 1
  fi
  if [ "$STATUS" = "needs_manual" ]; then
    echo "    this intent is parked in needs_manual. If it is over the per-transaction mint cap, raise the"
    echo "    cap first (set-mint-caps): the outbox re-checks the caps before it submits, and would park it again."
  fi

  echo ""
  echo "=== approving ==="
  # Same shape as create: the id travels via -e, the token expands inside the container.
  RESP=$(docker exec -e IID="$INTENT_ID" "$SVC" sh -c \
    'curl -sS --fail-with-body -X POST -H "Authorization: Bearer $APP_APPROVER_TOKEN" \
     "http://127.0.0.1:8090/internal/mint-intents/$IID/approve"' 2>&1 || true)
  echo "    response: $(show_resp "$RESP")"

  echo ""
  echo "=== intent after ==="
  show_intent "$INTENT_ID"

  AFTER=$(docker exec "$PG" psql -U treasury -d treasury -tAc \
    "select status from mint_intents where id = '$INTENT_ID';" 2>/dev/null | tr -d '[:space:]')
  if [ "$AFTER" = "approved" ] || [ "$AFTER" = "submitted" ] || [ "$AFTER" = "credited" ]; then
    echo ""
    echo "approved. The outbox submits it on its next pass, and re-checks the caps and the node's"
    echo "sync state immediately before submitting — approval is not authorisation to mint."
    exit 0
  fi
  echo ""
  echo "ABORT: intent is still '$AFTER' after the approve call."
  exit 1
fi

echo "ABORT: ACTION must be 'create' or 'approve', got '$ACTION'."
exit 1
