#!/usr/bin/env bash
# Dump, encrypt and retain the treasury and orchestrator databases.
#
# WHY THIS EXISTS
#
# The chain records that a Mint happened and that a Burn happened. It does not record which
# off-chain USDT payment a mint answered, which user a deposit address belongs to, or which
# redemption intent a burn was tagged for. All of that lives in these two Postgres databases, so
# losing them means losing the ability to honour a redemption or to tell a depositor what became
# of their money. They are the off-chain half of the peg.
#
# Until now nothing dumped them. The named Docker volumes survive container recreation, which is
# what made the gap easy to miss: the data looks safe right up until the host is gone.
#
# WHAT THIS IS NOT
#
# A local dump is NOT a backup. With BACKUP_REMOTE unset this still runs and still writes an
# encrypted dump, but it says loudly that the copy shares a disk with the thing it is backing up.
# Readiness item D1 stays open until the dump lands elsewhere AND a restore has been performed.
# See docs/BACKUP-RESTORE.md.
#
# Reads from .env, by grep rather than by sourcing: sourcing would execute whatever is in there and
# would pull DEPOSIT_MNEMONIC into the environment of a script that has no business holding it.

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "ABORT: no .env here ($(pwd))."
  exit 1
fi

# First match wins, `=` split on the first one only, surrounding double quotes stripped.
env_get() {
  grep -E "^$1=" .env | head -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//'
}

# The environment wins over .env, so a rehearsal can inject an ephemeral passphrase
# without writing a secret to the host. Real backups still take theirs from .env.
BACKUP_PASSPHRASE="${BACKUP_PASSPHRASE:-$(env_get BACKUP_PASSPHRASE)}"
BACKUP_REMOTE="${BACKUP_REMOTE:-$(env_get BACKUP_REMOTE)}"
RETAIN="${BACKUP_RETAIN:-$(env_get BACKUP_RETAIN)}"
RETAIN="${RETAIN:-14}"
TREASURY_PASSWORD="$(env_get TREASURY_POSTGRES_PASSWORD)"
ORCHESTRATOR_PASSWORD="$(env_get ORCHESTRATOR_POSTGRES_PASSWORD)"

# A ledger dump in the clear is worse than no dump: it is every user's pk, deposit address and
# amount, in a file somebody will eventually copy somewhere convenient.
if [ -z "$BACKUP_PASSPHRASE" ]; then
  echo "ABORT: BACKUP_PASSPHRASE is not set in .env."
  echo "  Generate one:  openssl rand -base64 48"
  echo "  Then store it somewhere that is NOT this host. A dump you cannot decrypt is not a"
  echo "  backup, and a passphrase living next to the dump protects nothing."
  exit 1
fi
if [ -z "$TREASURY_PASSWORD" ] || [ -z "$ORCHESTRATOR_PASSWORD" ]; then
  echo "ABORT: TREASURY_POSTGRES_PASSWORD or ORCHESTRATOR_POSTGRES_PASSWORD missing from .env."
  exit 1
fi
export BACKUP_PASSPHRASE

BACKUP_DIR="${BACKUP_DIR:-backups}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# Overridable because the dev compose project uses a different prefix, and a container name is a
# worse thing to hardcode than to parameterise.
TREASURY_CONTAINER="${TREASURY_CONTAINER:-clutch-stage-treasury-postgres-1}"
ORCHESTRATOR_CONTAINER="${ORCHESTRATOR_CONTAINER:-clutch-stage-orchestrator-postgres-1}"

dump_one() {
  local container="$1" db="$2" user="$3" password="$4" out="$5"

  if ! docker inspect "$container" >/dev/null 2>&1; then
    echo "ABORT: container $container not found. Set TREASURY_CONTAINER/ORCHESTRATOR_CONTAINER."
    exit 1
  fi

  # -Fc is Postgres's custom format: compressed, and restorable table-by-table with pg_restore,
  # which matters when the reason you are restoring is one corrupted table rather than a dead host.
  #
  # PGPASSWORD goes in via `docker exec -e KEY=value` rather than being exported here, so it is
  # never in this shell's environment and never inherited by anything else the script runs.
  #
  # pipefail is set, so a pg_dump failure fails the script rather than leaving a valid encryption
  # of a truncated dump — which would look exactly like a good backup.
  echo "  dumping $db from $container"
  docker exec -e "PGPASSWORD=$password" -i "$container" pg_dump -U "$user" -d "$db" -Fc \
    | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass env:BACKUP_PASSPHRASE \
    > "$out"
  chmod 600 "$out"

  # An empty or trivially small output means the dump failed in a way the exit code missed.
  local size
  size=$(wc -c < "$out")
  if [ "$size" -lt 1024 ]; then
    echo "ABORT: $out is only ${size} bytes — treating that as a failed dump, not a small database."
    rm -f "$out"
    exit 1
  fi
  echo "  wrote $out (${size} bytes, encrypted)"
}

echo "=== treasury backup $STAMP ==="
dump_one "$TREASURY_CONTAINER" treasury treasury "$TREASURY_PASSWORD" \
  "$BACKUP_DIR/treasury-$STAMP.dump.enc"
dump_one "$ORCHESTRATOR_CONTAINER" orchestrator orchestrator "$ORCHESTRATOR_PASSWORD" \
  "$BACKUP_DIR/orchestrator-$STAMP.dump.enc"

# rclone rather than a provider CLI: the destination is a decision for whoever operates this, and
# every provider-specific tool is one more thing to install on the host.
if [ -n "$BACKUP_REMOTE" ]; then
  if ! command -v rclone >/dev/null 2>&1; then
    echo "ABORT: BACKUP_REMOTE is set but rclone is not installed. Install it, or unset"
    echo "  BACKUP_REMOTE to keep local-only dumps (which do NOT satisfy readiness item D1)."
    exit 1
  fi
  echo "=== copying to $BACKUP_REMOTE ==="
  rclone copy "$BACKUP_DIR/treasury-$STAMP.dump.enc" "$BACKUP_REMOTE" --no-traverse
  rclone copy "$BACKUP_DIR/orchestrator-$STAMP.dump.enc" "$BACKUP_REMOTE" --no-traverse
  echo "  copied both dumps off host"
else
  echo ""
  echo "WARNING: BACKUP_REMOTE is not set, so these dumps are on the SAME DISK as the databases"
  echo "  they came from. That survives a container or volume mistake and nothing else. Readiness"
  echo "  item D1 is not satisfied by this. Set BACKUP_REMOTE to an rclone destination."
fi

# Retention, so this cannot fill the disk it shares with Postgres.
echo "=== retention (keeping $RETAIN of each) ==="
for prefix in treasury orchestrator; do
  # shellcheck disable=SC2012
  ls -1t "$BACKUP_DIR/$prefix-"*.dump.enc 2>/dev/null | tail -n "+$((RETAIN + 1))" | while read -r old; do
    echo "  pruning $old"
    rm -f "$old"
  done
done

echo ""
echo "=== done ==="
ls -1t "$BACKUP_DIR"/*.dump.enc 2>/dev/null | head -4 | sed 's/^/  /'
echo ""
echo "A dump nobody has restored is a hypothesis. docs/BACKUP-RESTORE.md has the rehearsal; D1"
echo "closes when that rehearsal has been performed, not when this script has run."
