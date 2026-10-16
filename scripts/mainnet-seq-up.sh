#!/usr/bin/env bash
#
# Start (or update) mainnet's own Seq, seq.clutchprotocol.io. Run from the repo root on the host, by
# "Mainnet — start Seq" (mainnet-seq-up.yml). Safe to run again.
#
#   bash scripts/mainnet-seq-up.sh
#
# What it does, in order:
#   1. Writes MAINNET_SEQ_ADMIN_PASSWORD into .env.mainnet if it is not there yet (48 random hex
#      characters). Never printed and never replaced. That is the login for seq.clutchprotocol.io,
#      user `admin`; read it from .env.mainnet on the host.
#   2. Starts `mainnet-seq` in its own compose project, clutch-main-seq (docker-compose.mainnet.seq.yml).
#      Nothing else: no validator, app or treasury container is created, recreated or restarted, and
#      the run fails if any of their start times moved.
#   3. Once Seq answers, logs in. On a new Seq that first login replaces the first-run password with
#      the admin password (Seq insists on a change before anything else works), then adds the
#      retention policy: delete every log event older than 7 days.
#
# The first-run password is derived from the admin password, so it is the same on every run and a
# second run does not recreate the container. It works only once, on an empty volume, and the first
# login replaces it.
#
# Never `down`, never `-v`. The volume holds logs only, but deleting it is still not this script's call.

set -euo pipefail
cd "$(dirname "$0")/.."

ENVF=.env.mainnet
PROJECT=clutch-main-seq
C="docker compose -p ${PROJECT} --env-file ${ENVF} -f docker-compose.mainnet.seq.yml"
SEQ=clutch-main-seq-mainnet-seq-1
DAYS=7

[ -f "$ENVF" ] || { echo "ABORT: $ENVF is not here."; exit 1; }
for net in clutch-mainnet clutch-stage_clutch-network; do
  docker network inspect "$net" >/dev/null 2>&1 || { echo "ABORT: docker network $net does not exist."; exit 1; }
done

echo "=== admin password ==="
if grep -q '^MAINNET_SEQ_ADMIN_PASSWORD=.' "$ENVF"; then
  echo "  MAINNET_SEQ_ADMIN_PASSWORD is in $ENVF already: kept"
else
  grep -q '^MAINNET_SEQ_ADMIN_PASSWORD=' "$ENVF" && { echo "ABORT: MAINNET_SEQ_ADMIN_PASSWORD is in $ENVF but empty. Delete that line and run again."; exit 1; }
  PW=$(openssl rand -hex 24)
  [ "${#PW}" -eq 48 ] || { echo "ABORT: could not generate a password."; exit 1; }
  # Appending keeps the file's owner and mode (600).
  [ -z "$(tail -c1 "$ENVF")" ] || echo "" >> "$ENVF"
  {
    echo "# The admin login for seq.clutchprotocol.io (user admin). Written by scripts/mainnet-seq-up.sh."
    echo "MAINNET_SEQ_ADMIN_PASSWORD=${PW}"
  } >> "$ENVF"
  unset PW
  echo "  MAINNET_SEQ_ADMIN_PASSWORD written to $ENVF (not printed)"
fi
SEQ_PW=$(sed -n 's/^MAINNET_SEQ_ADMIN_PASSWORD=//p' "$ENVF" | tail -1 | tr -d '\r')
export MAINNET_SEQ_FIRSTRUN_PASSWORD
MAINNET_SEQ_FIRSTRUN_PASSWORD=$(printf 'first-run:%s' "$SEQ_PW" | sha256sum | cut -c1-40)

# Compose's own message is not printed: it can quote a line of the env file.
$C config -q >/dev/null 2>&1 || { echo "ABORT: docker-compose.mainnet.seq.yml does not render with $ENVF."; exit 1; }

others() {
  docker ps --format '{{.Names}}' \
    | { grep -E '^clutch-main-' || true; } | { grep -v "^${PROJECT}-" || true; } | sort \
    | while read -r n; do echo "$n $(docker inspect -f '{{.State.StartedAt}}' "$n")"; done
}
before=$(others)

echo ""
echo "=== start ==="
$C pull -q mainnet-seq
$C up -d mainnet-seq
$C ps

echo ""
echo "=== waiting for Seq to answer ==="
ok=0
for _ in $(seq 1 30); do
  if docker run --rm --network "container:$SEQ" curlimages/curl:8.10.1 -fsS --max-time 4 -o /dev/null http://127.0.0.1:80/api 2>/dev/null; then
    ok=1; break
  fi
  sleep 4
done
[ "$ok" = 1 ] || { echo "ABORT: Seq never answered. On the host: docker logs --tail 50 $SEQ"; exit 1; }
echo "  Seq answers"

echo ""
SEQ_FIRSTRUN_PW="$MAINNET_SEQ_FIRSTRUN_PASSWORD" CHAIN=mainnet MODE=apply DAYS="$DAYS" bash scripts/seq-retention.sh

echo ""
echo "=== reachable from the mainnet services? ==="
# The validators sit on clutch-mainnet only; nginx and the Hub API also reach it on the stage network.
for net in clutch-mainnet clutch-stage_clutch-network; do
  code=$(docker run --rm --network "$net" curlimages/curl:8.10.1 -s -o /dev/null -w '%{http_code}' --max-time 5 http://mainnet-seq:80/api 2>/dev/null || true)
  echo "  http://mainnet-seq:80 on $net: ${code:-no answer}"
  [ "$code" = "200" ] || { echo "ABORT: mainnet-seq does not answer on $net."; exit 1; }
done

echo ""
echo "=== nothing else moved? ==="
after=$(others)
if [ "$before" != "$after" ]; then
  echo "FAILED: a mainnet container other than Seq changed during this run."
  diff <(echo "$before") <(echo "$after") || true
  exit 1
fi
echo "  $(echo "$after" | grep -c . || true) other mainnet containers, start times unchanged"
