#!/usr/bin/env bash
#
# Set the treasury's minting breaker, stopping new mints until a human clears it.
#
# Readiness item G3. `POST /internal/halt` existed in treasury-service and nothing could reach it:
# resuming had a workflow, halting did not. An operator who needed to stop minting had to SSH in
# and curl with the Approver token by hand, which is the position you least want to be in at the
# moment you have decided something is wrong.
#
# This is the control you reach for when you SUSPECT rather than know. Halting is cheap and fully
# reversible: deposits keep being credited on chain and the reserve total stays correct, only new
# CLT issuance stops. Being wrong about halting costs a delay. Being slow to halt, when something
# is actually wrong, costs unbacked CLT.
#
# It does NOT touch:
#   - the payout workers, which run regardless of this flag
#   - already-approved intents mid-flight
#   - anything on the chain
#
#   REASON="tron verifier looked wrong, investigating" bash scripts/halt-minting.sh

set -euo pipefail

REASON="${REASON:?REASON must be set — the halt_reason column is the only account of why}"

# Constrain the reason rather than escape it. This string crosses the host shell, `docker exec`,
# an inner `sh -c` and a JSON body, and an escaper correct through all four layers is more code
# than the problem deserves — the first attempt at one was silently wrong. A halt reason needs
# none of the characters that would break any of those layers.
case "$REASON" in
  *[!A-Za-z0-9\ ._,:\;\(\)/-]*)
    echo "ABORT: REASON may contain only letters, digits, spaces and . _ , : ; ( ) / -"
    echo "  Keep it short and plain. The point is the audit trail, not prose."
    exit 1 ;;
esac
if [ "${#REASON}" -gt 200 ]; then
  echo "ABORT: REASON is ${#REASON} characters; keep it under 200."
  exit 1
fi

PG=clutch-stage-treasury-postgres-1
SVC=clutch-stage-treasury-service-1

echo "=== breaker before ==="
docker exec "$PG" psql -U treasury -d treasury \
  -c "select minting_halted, halt_reason, updated_at from breaker_state;" 2>&1 | sed 's/^/    /'

ALREADY=$(docker exec "$PG" psql -U treasury -d treasury -tAc \
  "select minting_halted from breaker_state;" 2>/dev/null | tr -d '[:space:]')
if [ "$ALREADY" = "t" ]; then
  echo ""
  echo "Already halted. Not overwriting the existing reason — the first one is the one that"
  echo "explains why minting stopped, and replacing it loses that."
  exit 0
fi

echo ""
echo "=== halting ==="
# The token is read INSIDE the container and never printed. Only an Approver may halt, the same
# role that may resume, so this uses the API rather than writing to the table — a row written
# behind the service's back has no actor recorded against it.
#
# APP_APPROVER_TOKEN, not APP_TREASURY_APPROVER_TOKEN. Both exist on this stack and differ by which
# side holds them: treasury-service reads APP_APPROVER_TOKEN as its own credential, while the
# orchestrator carries APP_TREASURY_* as the tokens it SENDS. Getting it wrong is a plain 401 with
# nothing naming the cause.
#
# The reason is already restricted to characters that need no escaping, so the body is built
# directly. Nothing here quotes anything the guard above did not already rule out.
RESP=$(docker exec -e "HALT_REASON=$REASON" "$SVC" sh -c   'curl -fsS -X POST -H "Authorization: Bearer $APP_APPROVER_TOKEN"      -H "Content-Type: application/json"      -d "{\"reason\":\"$HALT_REASON\"}"      http://127.0.0.1:8090/internal/halt' 2>&1 || true)
echo "    response: ${RESP:-<none>}"

echo ""
echo "=== breaker after ==="
docker exec "$PG" psql -U treasury -d treasury \
  -c "select minting_halted, halt_reason, updated_at from breaker_state;" 2>&1 | sed 's/^/    /'

NOW=$(docker exec "$PG" psql -U treasury -d treasury -tAc \
  "select minting_halted from breaker_state;" 2>/dev/null | tr -d '[:space:]')
if [ "$NOW" = "t" ]; then
  echo ""
  echo "minting is halted. Deposits are still credited and the reserve total is still correct;"
  echo "no new CLT is being issued."
  echo ""
  echo "To clear it: Actions -> Resume minting (stage). That refuses while the latest"
  echo "reconciliation is still a mismatch, which is deliberate — see docs/ON-CALL.md."
  exit 0
fi
echo ""
echo "ABORT: the breaker is NOT set after the halt call. Minting is still live."
echo "  Check the response above. A 401 means the wrong token; a 403 means the token is not the"
echo "  Approver's. Do not assume this worked."
exit 1
