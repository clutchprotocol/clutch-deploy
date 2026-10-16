#!/usr/bin/env bash
#
# Show or set how long Seq keeps logs. Run from the repo root on the host, by
# "Stage host — Seq log retention".
#
#   MODE=check bash scripts/seq-retention.sh    show the policies and the size of Seq's data
#   MODE=apply bash scripts/seq-retention.sh    add "delete all log events after DAYS days" (default 7)
#   CHAIN=mainnet ...                           the same for mainnet's own Seq (default stage)
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

# CHAIN=stage (default): the testnet's Seq, seq-stage.clutchprotocol.io, admin login in .env.testnet.
# CHAIN=mainnet: mainnet's own Seq, seq.clutchprotocol.io (docker-compose.mainnet.seq.yml), admin
# password MAINNET_SEQ_ADMIN_PASSWORD in .env.mainnet, written by scripts/mainnet-seq-up.sh.
CHAIN="${CHAIN:-stage}"
case "$CHAIN" in
  stage)
    SEQ=clutch-stage-seq-1; ENVF=.env.testnet; USER_KEY=SEQ_ADMIN_USERNAME; PW_KEY=SEQ_ADMIN_PASSWORD ;;
  mainnet)
    SEQ=clutch-main-seq-mainnet-seq-1; ENVF=.env.mainnet; USER_KEY=MAINNET_SEQ_ADMIN_USERNAME; PW_KEY=MAINNET_SEQ_ADMIN_PASSWORD ;;
  *) echo "ABORT: CHAIN must be stage or mainnet, got '$CHAIN'."; exit 1 ;;
esac
docker inspect "$SEQ" >/dev/null 2>&1 || { echo "ABORT: container $SEQ is not here."; exit 1; }
[ -f "$ENVF" ] || { echo "ABORT: $ENVF is not here."; exit 1; }
SEQ_USER=$(sed -n "s/^${USER_KEY}=//p" "$ENVF" | tail -1 | tr -d '\r')
SEQ_PW=$(sed -n "s/^${PW_KEY}=//p" "$ENVF" | tail -1 | tr -d '\r')
[ -n "$SEQ_USER" ] || SEQ_USER=admin
[ -n "$SEQ_PW" ] || { echo "ABORT: $PW_KEY is not set in $ENVF."; exit 1; }
# On a Seq nobody has logged in to yet, the first login has to change the first-run password.
# mainnet-seq-up.sh passes it in; it is derived from the admin password, never stored.
SEQ_FIRSTRUN_PW="${SEQ_FIRSTRUN_PW:-}"

echo "=== disk ==="
df -h / | tail -1
echo "  Seq data: $(docker exec "$SEQ" du -sh /data 2>/dev/null | awk '{print $1}' || echo '?')"
echo ""
echo "=== Seq retention ($MODE) ==="
SEQ_USER="$SEQ_USER" SEQ_PW="$SEQ_PW" SEQ_FIRSTRUN_PW="$SEQ_FIRSTRUN_PW" docker run --rm --network "container:$SEQ" \
  -e SEQ_USER -e SEQ_PW -e SEQ_FIRSTRUN_PW -v "$PWD/scripts:/s:ro" python:3-alpine \
  python3 /s/seq-retention.py "$MODE" "$DAYS"
