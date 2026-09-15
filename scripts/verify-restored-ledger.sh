#!/usr/bin/env bash
# The verification readiness item D1 actually asks for: reconciliation run GREEN against a ledger
# restored from the off-host backup.
#
# Row counts prove a restore is not empty. They do not prove it is coherent — that the mint intents,
# the chain outbox and the balances in that copy still add up against the real chain and real
# custody. This is the difference between having a backup and knowing it is worth something.
#
# What this does, in order:
#   1. Fetch the newest treasury and orchestrator dumps FROM THE REMOTE, not from local disk. The
#      local copies share a disk with the databases they came from; restoring those tests nothing
#      about the thing that survives losing the host.
#   2. Decrypt with the passphrase in .env — the real one, so a passphrase that no longer opens the
#      real dumps fails here rather than on the day it matters.
#   3. Restore each into <db>_restore_<stamp>. restore-treasury-db.sh cannot target a live database.
#   4. Run `treasury-service --reconcile-once` against the restored treasury.
#   5. Drop both copies, whatever happened.
#
# Step 4 uses --reconcile-once rather than an ordinary service on purpose. A normal treasury-service
# starts the sweeper, the chain outbox and the payout workers, all of which act on chain — so an
# instance reading a COPY of chain_outbox would re-broadcast transactions already submitted and
# re-sweep addresses already swept. Verifying a backup must not be able to move money.

set -euo pipefail

cd "$(dirname "$0")/.."

env_get() {
  # `|| true` because an absent key is an empty answer, not a failure. Under `set -euo pipefail` a
  # grep matching nothing fails the pipeline and kills the script inside a command substitution,
  # with no output at all. That is exactly how the first rehearsal died.
  grep -E "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' || true
}

REMOTE="$(env_get BACKUP_REMOTE)"
PGPASS="$(env_get TREASURY_POSTGRES_PASSWORD)"

if [ -z "$REMOTE" ]; then
  echo "ABORT: BACKUP_REMOTE is not set. There is no off-host copy to verify, and verifying the"
  echo "  local one would prove nothing about surviving the loss of this host."
  exit 1
fi
if [ -z "$PGPASS" ]; then
  echo "ABORT: TREASURY_POSTGRES_PASSWORD is not in .env."
  exit 1
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TREASURY_TARGET="treasury_restore_$STAMP"
ORCH_TARGET="orchestrator_restore_$STAMP"
WORKDIR="$(mktemp -d)"

TREASURY_CONTAINER="${TREASURY_CONTAINER:-clutch-stage-treasury-postgres-1}"
ORCH_CONTAINER="${ORCHESTRATOR_CONTAINER:-clutch-stage-orchestrator-postgres-1}"

# Cleanup runs on every exit path, including a failed reconciliation. A restored ledger left behind
# is a second copy of every deposit and every mint intent sitting on the same box, and the whole
# point of the exercise is that copies of this data are handled deliberately.
cleanup() {
  local rc=$?
  echo ""
  echo "=== cleanup ==="
  rm -rf "$WORKDIR"
  docker exec -e "PGPASSWORD=$PGPASS" -i "$TREASURY_CONTAINER" \
    psql -U treasury -d postgres -c "DROP DATABASE IF EXISTS \"$TREASURY_TARGET\";" >/dev/null 2>&1 \
    && echo "  dropped $TREASURY_TARGET" || echo "  (no $TREASURY_TARGET to drop)"
  docker exec -e "PGPASSWORD=$(env_get ORCHESTRATOR_POSTGRES_PASSWORD)" -i "$ORCH_CONTAINER" \
    psql -U orchestrator -d postgres -c "DROP DATABASE IF EXISTS \"$ORCH_TARGET\";" >/dev/null 2>&1 \
    && echo "  dropped $ORCH_TARGET" || echo "  (no $ORCH_TARGET to drop)"
  exit $rc
}
trap cleanup EXIT

fetch_newest() {
  # Dump names carry a sortable UTC stamp, so lexical order is chronological order.
  local prefix="$1"
  local name
  name="$(rclone lsf "$REMOTE" --include "$prefix-*.dump.enc" | sort | tail -1)"
  if [ -z "$name" ]; then
    echo "ABORT: no $prefix dump in $REMOTE. Run the backup workflow first." >&2
    exit 1
  fi
  rclone copy "$REMOTE/$name" "$WORKDIR" --no-traverse
  echo "$name"
}

echo "=== 1/4 fetching the newest dumps from $REMOTE ==="
TREASURY_DUMP="$(fetch_newest treasury)"
ORCH_DUMP="$(fetch_newest orchestrator)"
echo "  $TREASURY_DUMP"
echo "  $ORCH_DUMP"

echo ""
echo "=== 2/4 restoring into $TREASURY_TARGET and $ORCH_TARGET ==="
RESTORE_TARGET="$TREASURY_TARGET" bash scripts/restore-treasury-db.sh "$WORKDIR/$TREASURY_DUMP"
RESTORE_TARGET="$ORCH_TARGET" bash scripts/restore-treasury-db.sh "$WORKDIR/$ORCH_DUMP"

echo ""
echo "=== 3/4 reconciling against the RESTORED treasury ledger ==="
echo "  (--reconcile-once: no sweeper, no outbox, no payout workers, no HTTP server)"

# The service's own compose definition supplies every other setting — tokens, node URLs, TronGrid,
# custody address. Only the database is redirected. `--no-deps` so this cannot start anything, and
# the repeated service name is because the image's CMD is the binary with no ENTRYPOINT, so the
# arguments have to name it.
FILES=(-f docker-compose.yml -f docker-compose.treasury.yml -f docker-compose.stage.cloudflare-flex.yml -f docker-compose.stage.treasury.yml)

set +e
docker compose -p clutch-stage "${FILES[@]}" run --rm --no-deps \
  -e "APP_DATABASE_URL=postgres://treasury:$PGPASS@treasury-postgres:5432/$TREASURY_TARGET" \
  treasury-service treasury-service --reconcile-once
RECONCILE_RC=$?
set -e

echo ""
echo "=== 4/4 verdict ==="
case "$RECONCILE_RC" in
  0)
    echo "  RECONCILED CLEAN against the restored ledger."
    echo ""
    echo "  This is the verification readiness item D1 asks for. Record today's date under D1 in"
    echo "  clutch-treasury/docs/mainnet-readiness.md, naming the dump that was restored:"
    echo "    $TREASURY_DUMP"
    ;;
  1)
    echo "  MISMATCH against the restored ledger."
    echo ""
    echo "  The restore loaded and the numbers do not add up. Do NOT record D1 as closed. Compare"
    echo "  the reconciliation_runs row this just wrote against the live database's latest run: if"
    echo "  live reconciles and the restore does not, the backup is losing data rather than the"
    echo "  reserve being short."
    ;;
  3)
    echo "  RAN, BUT NOT CLEAN."
    echo ""
    echo "  The status above is one the mint gate tolerates -- over_backed_drift means the ledger"
    echo "  counts more as issued than the chain holds, which is the safe direction -- but it is"
    echo "  raised as a p1 and it is not a clean reserve. D1 asks for GREEN against the restored"
    echo "  ledger, so this does not close it."
    echo ""
    echo "  Check whether LIVE reports the same status before suspecting the backup. Identical"
    echo "  numbers on both sides mean the restore is faithful and the drift is a pre-existing"
    echo "  ledger problem to fix on its own terms:"
    echo "    curl -s https://explorer-stage.clutchprotocol.io/api/v1/reserve"
    ;;
  *)
    echo "  COULD NOT RUN (exit $RECONCILE_RC)."
    echo ""
    echo "  Not a mismatch — reconciliation never completed, most likely the node or TronGrid was"
    echo "  unreachable. Nothing is proved either way; run it again."
    ;;
esac

exit "$RECONCILE_RC"
