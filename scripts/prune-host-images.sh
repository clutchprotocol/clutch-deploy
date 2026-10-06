#!/usr/bin/env bash
#
# Remove the Docker images on the stage host that no container uses and that are older than 7 days.
# Run from the repo root on the host, by "Stage host — remove unused Docker images".
#
#   MODE=check bash scripts/prune-host-images.sh    list what would go and show the disk; remove nothing
#   MODE=prune bash scripts/prune-host-images.sh    remove them
#
# Why it exists. Every deploy pulls new sha-<7> images, and nothing ever removed the old ones. On
# 2026-10-06 the host held 263 images (17 in use, about 20 GB) with 3.6 GB free, and Seq stopped
# taking logs: "Free storage space on this server has dropped below the configured limit".
#
# What goes: an image that no container uses, running or stopped, and that was created more than
# KEEP_HOURS ago (default 168, 7 days). That is exactly `docker image prune -a --filter until=<hours>h`.
# An image a container uses is never removed, so nothing that runs stops. A removed image is pulled
# again from its registry when something needs it: a rollback to an old pin, or a helper image that
# a script runs with `docker run --rm`.
#
# It prints image names, sizes and disk space only.

set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${MODE:?MODE must be check or prune}"
case "$MODE" in check|prune) ;; *) echo "ABORT: MODE must be check or prune, got '$MODE'."; exit 1 ;; esac
KEEP_HOURS="${KEEP_HOURS:-168}"
case "$KEEP_HOURS" in ''|*[!0-9]*) echo "ABORT: KEEP_HOURS must be a whole number of hours, got '$KEEP_HOURS'."; exit 1 ;; esac
[ "$KEEP_HOURS" -ge 24 ] || { echo "ABORT: KEEP_HOURS below 24 is refused: a deploy may still need the image."; exit 1; }

echo "=== disk before ==="
df -h / | tail -1
docker system df

# The images that any container uses, running or stopped. These are never listed or removed.
used=$(docker ps -aq | xargs -r docker inspect --format '{{.Image}}' | sort -u)
cutoff=$(( $(date +%s) - KEEP_HOURS * 3600 ))

echo
echo "=== images no container uses, created more than ${KEEP_HOURS} hours ago ==="
n=0
while IFS='|' read -r id name created size; do
  [ -n "$id" ] || continue
  if [ -n "$used" ] && printf '%s\n' "$used" | grep -qxF -- "$id"; then
    continue
  fi
  # CreatedAt looks like "2026-09-25 14:03:11 +0000 UTC"; date reads it without the zone name.
  ts=$(date -d "${created% *}" +%s 2>/dev/null || echo 0)
  if [ "$ts" -gt 0 ] && [ "$ts" -lt "$cutoff" ]; then
    echo "  $name  $size  (created ${created% *})"
    n=$((n + 1))
  fi
done <<EOF
$(docker image ls --no-trunc --format '{{.ID}}|{{.Repository}}:{{.Tag}}|{{.CreatedAt}}|{{.Size}}')
EOF
echo "$n image tag(s)."

if [ "$MODE" = check ]; then
  echo
  echo "check only: nothing was removed."
  exit 0
fi

echo
echo "=== removing them ==="
docker image prune -a -f --filter "until=${KEEP_HOURS}h"

echo
echo "=== disk after ==="
df -h / | tail -1
docker system df
