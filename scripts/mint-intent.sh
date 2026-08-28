#!/usr/bin/env bash
#
# The four-eyes mint flow, as two separate actions.
#
#   ACTION=create   BENEFICIARY=0x... AMOUNT_CLT=990000000 REASON="..."   bash scripts/mint-intent.sh
#   ACTION=approve  INTENT_ID=<uuid>                                      bash scripts/mint-intent.sh
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

PG=clutch-stage-treasury-postgres-1
SVC=clutch-stage-treasury-service-1
ACTION="${ACTION:?ACTION must be create or approve}"

show_intent() {
  docker exec "$PG" psql -U treasury -d treasury \
    -c "select id, beneficiary, amount_clt, status, created_by, approved_by, created_at
        from mint_intents where id = '$1';" 2>&1 | sed 's/^/    /'
}

if [ "$ACTION" = "create" ]; then
  BENEFICIARY="${BENEFICIARY:?BENEFICIARY must be set}"
  AMOUNT_CLT="${AMOUNT_CLT:?AMOUNT_CLT must be set}"
  REASON="${REASON:?REASON must be set — this is the only record of WHY money was created}"

  case "$AMOUNT_CLT" in
    ''|*[!0-9]*) echo "ABORT: AMOUNT_CLT must be a positive integer in micro-dollars (1 USD = 1000000)."; exit 1;;
  esac

  # There is no idempotency key available for a manual mint: the treasury's `client_ref` requires
  # `expected_amount_usdt`, which pins the verifier to an on-chain transfer that a correction mint
  # does not have. So a re-run WOULD create a second intent and mint twice. This check is what
  # stands in for that -- refuse when an equivalent intent is already live.
  DUPES=$(docker exec "$PG" psql -U treasury -d treasury -tAc \
    "select count(*) from mint_intents
     where beneficiary = '$BENEFICIARY' and amount_clt = $AMOUNT_CLT
       and status in ('created','approved','submitted','credited');" 2>/dev/null | tr -d '[:space:]')

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
  echo "    beneficiary: $BENEFICIARY"
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

  echo "    response: $RESP"
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

  echo "=== intent before approval ==="
  show_intent "$INTENT_ID"

  STATUS=$(docker exec "$PG" psql -U treasury -d treasury -tAc \
    "select status from mint_intents where id = '$INTENT_ID';" 2>/dev/null | tr -d '[:space:]')
  if [ -z "$STATUS" ]; then
    echo "ABORT: no such intent."
    exit 1
  fi
  if [ "$STATUS" != "created" ]; then
    echo "ABORT: intent is '$STATUS', not 'created'. Only a freshly created intent can be approved."
    exit 1
  fi

  echo ""
  echo "=== approving ==="
  # Same shape as create: the id travels via -e, the token expands inside the container.
  RESP=$(docker exec -e IID="$INTENT_ID" "$SVC" sh -c \
    'curl -sS --fail-with-body -X POST -H "Authorization: Bearer $APP_APPROVER_TOKEN" \
     "http://127.0.0.1:8090/internal/mint-intents/$IID/approve"' 2>&1 || true)
  echo "    response: $RESP"

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
