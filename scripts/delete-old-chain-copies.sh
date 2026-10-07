#!/usr/bin/env bash
#
# Delete the copies of old mainnet chains that scripts/reset-mainnet-chain.sh keeps in backups/.
# Run from the repo root on the stage host, by "Mainnet - delete the copies of old chains".
#
#   MODE=check  bash scripts/delete-old-chain-copies.sh    list what would be deleted, delete nothing
#   MODE=delete bash scripts/delete-old-chain-copies.sh    delete it
#
# Why this exists. Every reset keeps a copy of the three data volumes of the chain it wipes
# (backups/mainnet-chain-<time>/, mode 700). The copy is only of use for a rollback, and the README
# kept beside it says to delete it once the new chain has run for a while. The workflows cannot run a
# command of their own choosing on the host (that is on purpose), so deleting it needed a script.
#
# What it will and will not delete, in this order. Anything that fails a check is SKIPPED with a
# reason, never deleted:
#   1. The folder name is exactly what the reset script makes: mainnet-chain-YYYYMMDDTHHMMSSZ.
#   2. It is a plain directory directly inside backups/ (not a link to somewhere else).
#   3. It holds only what the reset script writes: node1.tgz, node2.tgz, node3.tgz and README, with
#      nothing in a subfolder. A folder that holds anything else is somebody's, not the script's.
# And in delete mode only: the three mainnet validators are running. The copy is the way back if a
# new chain does not start, so it is not deleted while the chain is down.
#
# It reads and prints names, sizes and each README (public text). It prints no secret: the copies hold
# chain data, and the validator keys live in .env.mainnet, not in a volume.

set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${MODE:?MODE must be check or delete}"
case "$MODE" in check|delete) ;; *) echo "ABORT: MODE must be check or delete, got '$MODE'."; exit 1 ;; esac

PROJECT=clutch-main
BK=backups

die() { printf 'ABORT: %s\n' "$1" >&2; exit 1; }

if [ ! -d "$BK" ]; then
  echo "There is no $BK/ folder here: nothing to do."
  exit 0
fi

if [ "$MODE" = delete ]; then
  for n in 1 2 3; do
    running=$(docker inspect -f '{{.State.Running}}' "${PROJECT}-mainnet-node${n}-1" 2>/dev/null || true)
    [ "$running" = true ] \
      || die "${PROJECT}-mainnet-node${n}-1 is not running. The copy is the way back if the new chain does not start, so nothing is deleted while the chain is down."
  done
  echo "OK: the three mainnet validators are running."
fi

found=0
skipped=0
total_kb=0
for d in "$BK"/mainnet-chain-*; do
  [ -e "$d" ] || [ -L "$d" ] || continue   # the pattern matched nothing
  name=$(basename "$d")

  if ! printf '%s' "$name" | grep -Eq '^mainnet-chain-[0-9]{8}T[0-9]{6}Z$'; then
    echo "SKIP  $name: the name is not one the reset script makes."
    skipped=$((skipped + 1))
    continue
  fi
  if [ -L "$d" ] || [ ! -d "$d" ]; then
    echo "SKIP  $name: it is not a plain directory."
    skipped=$((skipped + 1))
    continue
  fi
  # Anything that is not one of the four plain files. A subfolder is not a plain file, so one at any
  # depth is found here too. -print -quit, not "| head -n 1": under pipefail head would break the pipe.
  odd=$(find "$d" -mindepth 1 \( ! -type f -o ! \( -name node1.tgz -o -name node2.tgz -o -name node3.tgz -o -name README \) \) -print -quit)
  if [ -n "$odd" ]; then
    echo "SKIP  $name: it holds something the reset script does not write ($(basename "$odd"))."
    skipped=$((skipped + 1))
    continue
  fi

  kb=$(du -sk "$d" | awk '{print $1}')
  case "$kb" in ''|*[!0-9]*) die "could not size $name." ;; esac
  echo "FOUND $name  ${kb} KB"
  if [ -f "$d/README" ]; then
    sed 's/^/        /' "$d/README"
  fi
  found=$((found + 1))
  total_kb=$((total_kb + kb))

  if [ "$MODE" = delete ]; then
    rm -rf -- "$d"
    [ ! -e "$d" ] || die "$name is still there after rm."
    echo "      deleted."
  fi
done

echo
if [ "$MODE" = check ]; then
  echo "check only: $found cop$([ "$found" -eq 1 ] && echo y || echo ies) would be deleted (${total_kb} KB), $skipped skipped. Nothing was changed."
else
  echo "deleted $found cop$([ "$found" -eq 1 ] && echo y || echo ies) (${total_kb} KB), $skipped skipped."
  echo "free on the disk now: $(df -Pk "$BK" | awk 'NR==2 {print $4}') KB"
fi
