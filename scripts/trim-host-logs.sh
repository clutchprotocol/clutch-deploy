#!/usr/bin/env bash
#
# Cut down the oversized Docker container logs and cap the systemd journal on the stage host.
# Run from the repo root on the host, by "Stage host — trim logs".
#
#   MODE=check bash scripts/trim-host-logs.sh    list what would be emptied; change nothing
#   MODE=trim  bash scripts/trim-host-logs.sh    cut them down and vacuum the journal
#
# Why it exists. No compose file and no /etc/docker/daemon.json sets log rotation, so every
# container's json-file log grows until the container is recreated. On 2026-10-16 they held 9.2 GB
# of a 38 GB disk (the mainnet Hub API alone 5.5 GB) and the journal 3.7 GB.
#
# What it does. A container log over MIN_MB (default 100) is cut down IN PLACE to its newest KEEP_MB
# (default 50), starting at a whole line so `docker logs` can still read it. Same file, same inode:
# the container keeps running and keeps appending, nothing restarts. The older lines are gone for
# good: Seq held only about 6 MB of events on 2026-10-16, so it is not a copy of them. The newest
# part is kept on purpose, so whatever made a log this big can still be read. The journal is vacuumed down to JOURNAL_MAX (default 500M). Nothing else is touched:
# no volume, no chain data, no database, no backup.
#
# Prints container names and sizes only, never log content.

set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${MODE:?MODE must be check or trim}"
case "$MODE" in check|trim) ;; *) echo "ABORT: MODE must be check or trim, got '$MODE'."; exit 1 ;; esac
MIN_MB="${MIN_MB:-100}"
KEEP_MB="${KEEP_MB:-50}"
case "$MIN_MB$KEEP_MB" in ''|*[!0-9]*) echo "ABORT: MIN_MB and KEEP_MB must be whole numbers."; exit 1 ;; esac
[ "$KEEP_MB" -lt "$MIN_MB" ] || { echo "ABORT: KEEP_MB must be below MIN_MB."; exit 1; }
JOURNAL_MAX="${JOURNAL_MAX:-500M}"

# As root directly, or else through a throwaway container that mounts only the containers folder.
# postgres:16-alpine is always on the host because the databases run it.
CDIR=/var/lib/docker/containers
as_root() {
  if [ "$(id -u)" = 0 ]; then
    "$@"
  else
    docker run --rm -v "$CDIR:$CDIR" --entrypoint "$1" postgres:16-alpine "${@:2}"
  fi
}
# Keep the newest KEEP_MB of a log, dropping the first (cut) line, and write it back into the same
# file: `cat > f` truncates and rewrites the inode docker holds open, where `mv` would orphan it.
keep_tail() {
  as_root sh -c 'tail -c "$1" "$2" | tail -n +2 > "$2.keep" && cat "$2.keep" > "$2" && rm -f "$2.keep"' \
    sh "$((KEEP_MB * 1048576))" "$1"
}

echo "=== disk before ==="
df -h / | tail -1
echo ""
echo "=== container logs over ${MIN_MB} MB (each would keep its newest ${KEEP_MB} MB) ==="
n=0
targets=""
while read -r id name; do
  f="$CDIR/$id/$id-json.log"
  bytes=$(as_root stat -c %s "$f" 2>/dev/null || echo 0)
  mb=$(( bytes / 1048576 ))
  if [ "$mb" -ge "$MIN_MB" ]; then
    echo "  ${mb} MB  $name"
    targets="$targets $f"
    n=$((n + 1))
  fi
done <<EOF
$(docker ps -a --no-trunc --format '{{.ID}} {{.Names}}')
EOF
echo "$n log file(s)."
echo ""
echo "=== systemd journal ==="
journalctl --disk-usage 2>/dev/null || echo "  journalctl not available"
echo "  would vacuum to: $JOURNAL_MAX"

if [ "$MODE" = check ]; then
  echo ""
  echo "check only: nothing was changed."
  exit 0
fi

echo ""
echo "=== cutting each down to its newest ${KEEP_MB} MB ==="
for f in $targets; do
  keep_tail "$f" && echo "  done: $(docker ps -a --no-trunc --filter "id=$(basename "$(dirname "$f")")" --format '{{.Names}}')"
done
echo ""
echo "=== vacuuming the journal ==="
if [ "$(id -u)" = 0 ]; then
  journalctl --vacuum-size="$JOURNAL_MAX" 2>&1 | tail -2 | sed 's/^/  /'
elif sudo -n true 2>/dev/null; then
  sudo journalctl --vacuum-size="$JOURNAL_MAX" 2>&1 | tail -2 | sed 's/^/  /'
else
  echo "  skipped: needs root"
fi
echo ""
echo "=== disk after ==="
df -h / | tail -1
