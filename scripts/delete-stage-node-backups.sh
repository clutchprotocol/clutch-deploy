#!/usr/bin/env bash
# Remove only the stage node1 fork backup approved on 2026-11-12.
# Run MODE=check first, after Inspect stage (probe chain) confirms recovery.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${MODE:?MODE must be check or delete}"
case "$MODE" in check|delete) ;; *) printf 'ABORT: MODE must be check or delete.\n' >&2; exit 1 ;; esac

die() { printf 'ABORT: %s\n' "$1" >&2; exit 1; }
BK=backups/stage-node1-data-20261029T165633Z
[ ! -L backups ] || die 'backups is a link.'
[ ! -L "$BK" ] || die "$BK is a link."
if [ ! -e "$BK" ]; then
  printf 'Backup is absent: %s\n' "$BK"
  exit 0
fi
[ -d "$BK" ] || die "$BK is not a directory."
odd=$(find "$BK" -mindepth 1 \( ! -type f -o ! \( -name data.tgz -o -name README \) \) -print -quit)
[ -z "$odd" ] || die 'Backup holds unexpected content; nothing deleted.'
# Inspect the target before any deletion. Never extract or run its contents.
ls -la -- "$BK"
du -sk -- "$BK"
if [ -f "$BK/README" ]; then
  sed 's/^/    /' "$BK/README"
fi
if [ "$MODE" = check ]; then
  printf 'Check only; nothing deleted.\n'
  exit 0
fi
for n in 1 2 3; do
  running=$(docker inspect -f '{{.State.Running}}' "clutch-stage-node${n}-1" 2>/dev/null || true)
  [ "$running" = true ] || die "clutch-stage-node${n}-1 is not running."
done
rm -rf -- "$BK"
[ ! -e "$BK" ] && [ ! -L "$BK" ] || die 'Backup remains after deletion.'
printf 'Deleted only %s\n' "$BK"
