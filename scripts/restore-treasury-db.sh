#!/usr/bin/env bash
# Restore an encrypted dump into a SEPARATE database, for the rehearsal readiness item D1 needs.
#
# This deliberately cannot overwrite a live database. It creates `<db>_restore_<stamp>` and loads
# into that, so the rehearsal can be performed on a running stage without a window where the real
# ledger is half-loaded. Promoting a restore to live is a different, manual operation: stop the
# services first, then rename, because a service holding a connection to a database being replaced
# is how a restore turns into an outage plus a corrupt ledger.
#
# Usage:  bash scripts/restore-treasury-db.sh backups/treasury-20260911T000000Z.dump.enc
#
# Reads BACKUP_PASSPHRASE from .env, the same one the dump was written with.

set -euo pipefail

cd "$(dirname "$0")/.."

DUMP="${1:-}"
if [ -z "$DUMP" ] || [ ! -f "$DUMP" ]; then
  echo "usage: bash scripts/restore-treasury-db.sh <path to .dump.enc>"
  echo ""
  echo "available:"
  ls -1t backups/*.dump.enc 2>/dev/null | sed 's/^/  /' || echo "  (none in backups/)"
  exit 1
fi

env_get() {
  grep -E "^$1=" .env | head -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//'
}

BACKUP_PASSPHRASE="$(env_get BACKUP_PASSPHRASE)"
if [ -z "$BACKUP_PASSPHRASE" ]; then
  echo "ABORT: BACKUP_PASSPHRASE is not set in .env — nothing here can decrypt that dump."
  exit 1
fi
export BACKUP_PASSPHRASE

# Which database this dump belongs to is in its filename, and guessing wrong would load an
# orchestrator dump into a treasury schema.
BASE="$(basename "$DUMP")"
case "$BASE" in
  treasury-*)     DB=treasury;     USER=treasury;     CONTAINER="${TREASURY_CONTAINER:-clutch-stage-treasury-postgres-1}";     PASSWORD="$(env_get TREASURY_POSTGRES_PASSWORD)" ;;
  orchestrator-*) DB=orchestrator; USER=orchestrator; CONTAINER="${ORCHESTRATOR_CONTAINER:-clutch-stage-orchestrator-postgres-1}"; PASSWORD="$(env_get ORCHESTRATOR_POSTGRES_PASSWORD)" ;;
  *)
    echo "ABORT: cannot tell which database $BASE came from."
    echo "  Expected a name starting with 'treasury-' or 'orchestrator-'."
    exit 1 ;;
esac

TARGET="${DB}_restore_$(date -u +%Y%m%dT%H%M%SZ)"

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "ABORT: container $CONTAINER not found."
  exit 1
fi

echo "=== restoring $BASE into $TARGET (NOT into $DB) ==="

psql_in() {
  docker exec -e "PGPASSWORD=$PASSWORD" -i "$CONTAINER" psql -U "$USER" -d postgres -v ON_ERROR_STOP=1 "$@"
}

psql_in -c "CREATE DATABASE \"$TARGET\";"
echo "  created $TARGET"

# Decrypt on this side of the pipe and stream in, so the plaintext dump never touches disk.
# pg_restore's own exit code is unreliable for -Fc dumps with owner/ACL differences, so warnings
# are expected and only a hard failure of the decrypt half is fatal. --no-owner/--no-acl keep
# those warnings from being about ownership that does not exist in a fresh database.
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass env:BACKUP_PASSPHRASE -in "$DUMP" \
  | docker exec -e "PGPASSWORD=$PASSWORD" -i "$CONTAINER" \
      pg_restore -U "$USER" -d "$TARGET" --no-owner --no-acl \
  || echo "  (pg_restore reported warnings — check the row counts below before concluding anything)"

echo ""
echo "=== row counts in $TARGET ==="
# The tables worth eyeballing: if these are zero the restore did not work, whatever else it said.
psql_in -d "$TARGET" -c "
  SELECT relname AS table, n_live_tup AS approx_rows
  FROM pg_stat_user_tables
  ORDER BY n_live_tup DESC
  LIMIT 12;" 2>/dev/null || docker exec -e "PGPASSWORD=$PASSWORD" -i "$CONTAINER" \
    psql -U "$USER" -d "$TARGET" -c "
      SELECT relname AS table, n_live_tup AS approx_rows
      FROM pg_stat_user_tables ORDER BY n_live_tup DESC LIMIT 12;"

echo ""
echo "=== next, and this is the part that closes D1 ==="
echo "  1. Compare the counts above against the live database. A restore that loads cleanly and"
echo "     is empty is the failure mode this rehearsal exists to catch."
echo "  2. Point a treasury-service instance at $TARGET and run reconciliation. Green against the"
echo "     restored ledger is the actual verification; a loadable dump is not."
echo "  3. Drop it when done:"
echo "       docker exec -e PGPASSWORD=... -i $CONTAINER psql -U $USER -d postgres -c 'DROP DATABASE \"$TARGET\";'"
echo ""
echo "Record the date you did this in clutch-treasury/docs/mainnet-readiness.md, item D1."
