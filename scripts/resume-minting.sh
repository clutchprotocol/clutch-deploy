#!/usr/bin/env bash
#
# Clear the treasury's minting breaker.
#
# The breaker latches on a reconciliation mismatch and only a human clears it — that is the design,
# and this script does not weaken it. It exists so the action is auditable and repeatable instead of
# being someone's ad-hoc curl, and so the Approver token stays on the host rather than travelling.
#
# It refuses to clear blind: if the most recent reconciliation run is itself a mismatch, resuming
# would re-halt on the next pass anyway, and doing it in a loop is how a breaker stops meaning
# anything. Fix the mismatch first.

set -euo pipefail

PG=clutch-stage-treasury-postgres-1
SVC=clutch-stage-treasury-service-1

echo "=== breaker before ==="
docker exec "$PG" psql -U treasury -d treasury \
  -c "select minting_halted, halt_reason, updated_at from breaker_state;" 2>&1 | sed 's/^/    /'

LAST=$(docker exec "$PG" psql -U treasury -d treasury -tAc \
  "select status from reconciliation_runs order by run_at desc limit 1;" 2>/dev/null | tr -d '[:space:]')
echo ""
echo "most recent reconciliation run: ${LAST:-<none>}"

if [ -z "$LAST" ]; then
  echo "ABORT: no reconciliation run recorded. Resuming now would mint against a reserve nobody has verified."
  exit 1
fi
if [ "$LAST" = "mismatch" ]; then
  echo "ABORT: the latest reconciliation is still a mismatch."
  echo "  Resuming would re-halt on the next pass. Fix the underlying discrepancy first."
  exit 1
fi

echo ""
echo "=== resuming ==="
# The token is read INSIDE the container and never printed. Only an Approver may resume; the role
# split is the whole point of the four-eyes design and this uses it rather than writing to the table.
#
# APP_APPROVER_TOKEN, not APP_TREASURY_APPROVER_TOKEN. Both exist on this stack and differ by which
# side holds them: treasury-service reads APP_APPROVER_TOKEN as its own credential, while the
# orchestrator carries APP_TREASURY_* as the tokens it SENDS to the treasury. Getting it wrong is a
# plain 401 with nothing naming the cause.
RESP=$(docker exec "$SVC" sh -c \
  'curl -fsS -X POST -H "Authorization: Bearer $APP_APPROVER_TOKEN" \
   http://127.0.0.1:8090/internal/resume' 2>&1 || true)
echo "    response: ${RESP:-<none>}"

echo ""
echo "=== breaker after ==="
docker exec "$PG" psql -U treasury -d treasury \
  -c "select minting_halted, halt_reason, updated_at from breaker_state;" 2>&1 | sed 's/^/    /'

STILL=$(docker exec "$PG" psql -U treasury -d treasury -tAc \
  "select minting_halted from breaker_state;" 2>/dev/null | tr -d '[:space:]')
if [ "$STILL" = "f" ]; then
  echo ""
  echo "minting is no longer halted."
  echo "NOTE: the node staleness guard is separate and still applies — mints stay parked while the"
  echo "      node reports is_syncing."
  exit 0
fi
echo ""
echo "ABORT: the breaker is still set after the resume call."
exit 1
