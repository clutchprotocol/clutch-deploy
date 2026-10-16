#!/usr/bin/env bash
#
# Show or set how long Seq keeps logs. Run from the repo root on the host, by
# "Stage host — Seq log retention".
#
#   MODE=check bash scripts/seq-retention.sh    show the policies and the size of Seq's data
#   MODE=apply bash scripts/seq-retention.sh    add "delete all log events after DAYS days" (default 7)
#
# Why it exists. Seq had no retention policy, so it kept every log line from every service on both
# networks. On 2026-10-16 its volume was 10.3 GB of a 38 GB disk at 91%. Seq is not published on the
# host and has no vhost, so its settings page is out of reach; this logs in to its API the way the
# UI does, with the admin login from .env.testnet. It changes Seq's settings only: no container
# restarts, and the chain, the databases and the backups are not touched.
#
# Prints sizes and policy settings only. The password goes to the container in its environment and
# is never printed.

set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${MODE:?MODE must be check or apply}"
case "$MODE" in check|apply) ;; *) echo "ABORT: MODE must be check or apply, got '$MODE'."; exit 1 ;; esac
DAYS="${DAYS:-7}"
case "$DAYS" in ''|*[!0-9]*) echo "ABORT: DAYS must be a whole number, got '$DAYS'."; exit 1 ;; esac
[ "$DAYS" -ge 1 ] || { echo "ABORT: DAYS must be at least 1."; exit 1; }

SEQ=clutch-stage-seq-1
docker inspect "$SEQ" >/dev/null 2>&1 || { echo "ABORT: container $SEQ is not here."; exit 1; }
[ -f .env.testnet ] || { echo "ABORT: .env.testnet is not here."; exit 1; }
SEQ_USER=$(sed -n 's/^SEQ_ADMIN_USERNAME=//p' .env.testnet | tail -1 | tr -d '\r')
SEQ_PW=$(sed -n 's/^SEQ_ADMIN_PASSWORD=//p' .env.testnet | tail -1 | tr -d '\r')
[ -n "$SEQ_USER" ] || SEQ_USER=admin
[ -n "$SEQ_PW" ] || { echo "ABORT: SEQ_ADMIN_PASSWORD is not set in .env.testnet."; exit 1; }

echo "=== disk ==="
df -h / | tail -1
echo "  Seq data: $(docker exec "$SEQ" du -sh /data 2>/dev/null | awk '{print $1}' || echo '?')"
echo ""
echo "=== Seq retention ($MODE) ==="
SEQ_USER="$SEQ_USER" SEQ_PW="$SEQ_PW" docker run --rm --network "container:$SEQ" \
  -e SEQ_USER -e SEQ_PW -v "$PWD/scripts:/s:ro" python:3-alpine \
  python3 /s/seq-retention.py "$MODE" "$DAYS"
