#!/usr/bin/env bash
#
# Set the treasury's mint caps (CHAIN=stage by default, or CHAIN=mainnet) and restart the service so it reads them.
#
#   PER_TX=1000000000 DAILY=2000000000 bash scripts/set-mint-caps.sh
#
# These are SAFETY LIMITS. Raising one is a deliberate act with a reason, and the reason belongs in
# the workflow log that invoked this. Put them back afterwards -- a cap raised "temporarily" and left
# is just a cap that no longer exists.
#
# Both matter: check_mint tests the per-transaction cap AND the rolling daily total, so a payment
# over the daily figure is refused even when the per-transaction one allows it.

set -euo pipefail
. "$(dirname "$0")/lib/chain.sh"
chain_select "${CHAIN:-stage}" || exit 1
E="$CH_ENV_FILE"
echo "treasury: $CH_NAME ($E)"

PER_TX="${PER_TX:?PER_TX must be set (micro-dollars; 1 USD = 1000000)}"
DAILY="${DAILY:?DAILY must be set (micro-dollars)}"

for v in "$PER_TX" "$DAILY"; do
  case "$v" in
    ''|*[!0-9]*) echo "ABORT: caps must be positive integers in micro-dollars, got '$v'."; exit 1;;
  esac
done
if [ "$PER_TX" -gt "$DAILY" ]; then
  echo "ABORT: per-transaction cap ($PER_TX) exceeds the daily cap ($DAILY)."
  echo "  A single mint could never clear both, so this combination refuses everything."
  exit 1
fi

if [ ! -f "$E" ]; then
  echo "ABORT: no $E here ($(pwd))."
  exit 1
fi

# Mainnet only: two more refusals, before anything is copied or written. The log of the workflow that
# runs this is public, so nothing printed below may quote a line of $E.
#   - $CH_TREASURY must be running. Without it, the restart below would start that one service alone,
#     with no database behind it.
#   - $E must be plain NAME=value lines (pf_lint). docker compose quotes a line it cannot read into
#     its error message, and a stray line of this file can be a secret.
if [ "$CH_NAME" = mainnet ]; then
  . "$(dirname "$0")/lib/mainnet-preflight.sh"
  if ! docker ps --format '{{.Names}}' | grep -qx "$CH_TREASURY"; then
    echo "ABORT: $CH_TREASURY is not running. Start the mainnet treasury first (Mainnet — start the treasury)."
    exit 1
  fi
  if ! pf_lint "$E"; then
    echo "ABORT: $E is not well-formed (see above). Nothing was changed."
    exit 1
  fi
fi

# One backup, overwritten each run. Every copy holds DEPOSIT_MNEMONIC, so the timestamped naming
# this replaces left one more plaintext copy of it on the host per run. Copy before deleting; the
# glob requires a character after `.bak.`, so it cannot match .env.bak itself.
cp -a "$E" "$E.bak"
chmod 600 "$E.bak"
rm -f "$E".bak.*

# Replace in place if present, append if not. sed -i on the file itself, NOT a mv: .env is
# bind-mounted by inode elsewhere in this stack and moving it silently detaches the mount.
set_var() {
  if grep -qE "^$1=" "$E"; then
    sed -i "s#^$1=.*#$1=$2#" "$E"
  else
    printf '%s=%s\n' "$1" "$2" >> "$E"
  fi
}

echo "=== before ==="
# The stage compose file has defaults for the caps. The mainnet one requires them and has none.
if [ "$CH_NAME" = mainnet ]; then
  UNSET_NOTE="the mainnet compose file has no default for the mint caps"
else
  UNSET_NOTE="compose defaults: 50000000 / 500000000"
fi
grep -E '^(PER_TX|DAILY)_MINT_CAP_CLT=' "$E" | sed 's/^/    /' || echo "    (unset — $UNSET_NOTE)"

set_var PER_TX_MINT_CAP_CLT "$PER_TX"
set_var DAILY_MINT_CAP_CLT "$DAILY"
chmod 600 "$E"

echo ""
echo "=== after ==="
grep -E '^(PER_TX|DAILY)_MINT_CAP_CLT=' "$E" | sed 's/^/    /'

# Recreate treasury-service so it reads the new environment. Only that service: nothing else
# consumes these, and recreating the whole stack restarts nodes for no reason.
echo ""
echo "=== restarting $CH_SVC_TREASURY ==="
if [ "$CH_NAME" = mainnet ]; then
  # All of compose's output is dropped on mainnet: its error text quotes the line of $E it cannot
  # read, and this log is public. A failure prints the command to run on the host instead.
  if ! chain_compose up -d --force-recreate --no-deps "$CH_SVC_TREASURY" >/dev/null 2>&1; then
    echo "ABORT: recreating $CH_SVC_TREASURY failed. The output is not printed, because the log is public. Run on the host: docker compose -p $CH_PROJECT --env-file $CH_ENV_FILE -f docker-compose.mainnet.treasury.yml up -d --force-recreate --no-deps $CH_SVC_TREASURY"
    exit 1
  fi
else
  chain_compose up -d --force-recreate --no-deps "$CH_SVC_TREASURY" 2>&1 | tail -5
fi

echo ""
echo "=== what the container now sees ==="
for i in $(seq 1 20); do
  v=$(docker exec "$CH_TREASURY" printenv APP_PER_TX_MINT_CAP_CLT 2>/dev/null || true)
  d=$(docker exec "$CH_TREASURY" printenv APP_DAILY_MINT_CAP_CLT 2>/dev/null || true)
  if [ -n "$v" ]; then
    echo "    APP_PER_TX_MINT_CAP_CLT=$v"
    echo "    APP_DAILY_MINT_CAP_CLT=$d"
    if [ "$v" = "$PER_TX" ] && [ "$d" = "$DAILY" ]; then
      echo ""
      echo "caps applied."
      # Only this one service was recreated, so only it read the whole file again. A setting other
      # than the two caps that changed in $E since the last start is still the old value in the
      # other two services.
      if [ "$CH_NAME" = mainnet ]; then
        echo "only $CH_SVC_TREASURY was restarted. If you also changed other settings in $E, run \"Mainnet — start the treasury\" so that every service reads them."
      fi
      # Re-check the WHOLE limit set, not just the two values written. These caps are not
      # independent: the redemption bounds live in two services that do not derive from each
      # other, and the fee has to stay under the minimum. Changing one number can break a
      # relationship elsewhere, and every one of those failures is quiet — a limit that refuses
      # everything, or one that protects nothing, or a burn that cannot be paid.
      echo ""
      ENV_FILE="$E" bash scripts/check-cap-invariants.sh
      exit 0
    fi
    echo "ABORT: the container is not reporting the values just written."
    exit 1
  fi
  sleep 2
done
echo "ABORT: $CH_SVC_TREASURY did not come back up."
exit 1
