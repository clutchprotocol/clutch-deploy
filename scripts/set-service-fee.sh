#!/usr/bin/env bash
#
# Set the operator's service fee on top-ups (CHAIN=stage by default, or CHAIN=mainnet) and restart the
# two services that read it: the treasury, which charges it, and the orchestrator, which shows it.
#
#   BPS=100 MIN_USDT=500000 ADDRESS=0x... bash scripts/set-service-fee.sh   # 1%, at least $0.50
#   BPS=0 bash scripts/set-service-fee.sh                                     # off
#
# The fee is BPS of what a deposit mints, at least MIN_USDT, minted as CLT to ADDRESS, never on a
# user's first top-up (clutch-treasury service_fee.rs). The two mints together are what the deposit
# alone would have minted, so the reserve and the caps are unchanged.
#
# A treasury image from before the fee ignores these settings, so the run ends by reading the line the
# treasury logs at start ("service fee: on, ..."), and fails without it.

set -euo pipefail
. "$(dirname "$0")/lib/chain.sh"
chain_select "${CHAIN:-stage}" || exit 1
E="$CH_ENV_FILE"
echo "treasury: $CH_NAME ($E)"

BPS="${BPS:?BPS must be set (basis points: 100 is 1%; 0 turns the fee off)}"
case "$BPS" in
  ''|*[!0-9]*) echo "ABORT: BPS must be a whole number of basis points, got '$BPS'."; exit 1 ;;
esac
if [ "$BPS" -gt 1000 ]; then
  echo "ABORT: BPS is $BPS, above 1000 (10%). The treasury refuses that as a likely typo."
  exit 1
fi
if [ "$BPS" -gt 0 ]; then
  MIN_USDT="${MIN_USDT:?MIN_USDT must be set (micro-USDT: 500000 is \$0.50; 0 for no minimum)}"
  ADDRESS="${ADDRESS:?ADDRESS must be set: the 0x address the fee is minted to}"
  case "$MIN_USDT" in
    ''|*[!0-9]*) echo "ABORT: MIN_USDT must be a whole number of micro-USDT, got '$MIN_USDT'."; exit 1 ;;
  esac
  if ! printf '%s' "$ADDRESS" | grep -qE '^0[xX][0-9a-fA-F]{40}$'; then
    echo "ABORT: ADDRESS must be 0x and 40 hex characters (a Clutch address, not a TRON one), got '$ADDRESS'."
    exit 1
  fi
  ADDRESS=$(printf '%s' "$ADDRESS" | tr 'A-F' 'a-f' | sed 's/^0X/0x/')
else
  MIN_USDT=0
  ADDRESS=""
fi

if [ ! -f "$E" ]; then
  echo "ABORT: no $E here ($(pwd))."
  exit 1
fi

# Mainnet only, as in set-mint-caps.sh: the treasury must be running (the restart below starts single
# services, with no database behind them otherwise), and the file must be plain NAME=value lines,
# because compose quotes a line it cannot read and this log is public.
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

# Checked before anything is written, from the values about to be written (the checker reads the
# environment first): a set the treasury would refuse at start must never reach the file.
if ! SERVICE_FEE_BPS="$BPS" SERVICE_FEE_MIN_USDT="$MIN_USDT" SERVICE_FEE_ADDRESS="$ADDRESS" \
     ENV_FILE="$E" bash scripts/check-cap-invariants.sh >/tmp/clutch-service-fee-check.$$ 2>&1; then
  cat /tmp/clutch-service-fee-check.$$
  rm -f /tmp/clutch-service-fee-check.$$
  echo "ABORT: the limits would not hold with this fee (see above). Nothing was changed."
  exit 1
fi
rm -f /tmp/clutch-service-fee-check.$$

# One backup, overwritten each run: every copy holds DEPOSIT_MNEMONIC.
cp -a "$E" "$E.bak"
chmod 600 "$E.bak"
rm -f "$E".bak.*

# Replace in place if present, append if not; sed -i keeps the file's inode.
set_var() {
  if grep -qE "^$1=" "$E"; then
    sed -i "s#^$1=.*#$1=$2#" "$E"
  else
    printf '%s=%s\n' "$1" "$2" >> "$E"
  fi
}
if [ -s "$E" ] && [ -n "$(tail -c1 "$E")" ]; then
  echo >> "$E"
fi

PATTERN='^SERVICE_FEE_(BPS|MIN_USDT|ADDRESS)='
echo "=== before ==="
grep -E "$PATTERN" "$E" | sed 's/^/    /' || echo "    (unset: no service fee)"
set_var SERVICE_FEE_BPS "$BPS"
set_var SERVICE_FEE_MIN_USDT "$MIN_USDT"
set_var SERVICE_FEE_ADDRESS "$ADDRESS"
chmod 600 "$E"
echo ""
echo "=== after ==="
grep -E "$PATTERN" "$E" | sed 's/^/    /'

echo ""
echo "=== restarting $CH_SVC_TREASURY and $CH_SVC_ORCH ==="
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [ "$CH_NAME" = mainnet ]; then
  # Compose's output is dropped on mainnet: its error text can quote a line of $E.
  if ! chain_compose up -d --force-recreate --no-deps "$CH_SVC_TREASURY" "$CH_SVC_ORCH" >/dev/null 2>&1; then
    echo "ABORT: recreating the two services failed. The output is not printed, because the log is public. Run on the host: docker compose -p $CH_PROJECT --env-file $CH_ENV_FILE -f docker-compose.mainnet.treasury.yml up -d --force-recreate --no-deps $CH_SVC_TREASURY $CH_SVC_ORCH"
    exit 1
  fi
else
  chain_compose up -d --force-recreate --no-deps "$CH_SVC_TREASURY" "$CH_SVC_ORCH" 2>&1 | tail -5
fi

echo ""
echo "=== what the treasury says ==="
for i in $(seq 1 30); do
  line=$(docker logs --since "$since" "$CH_TREASURY" 2>&1 | grep -oE 'service fee: (off|on, .*)' | tail -1 || true)
  if [ -n "$line" ]; then
    echo "    $line"
    if [ "$BPS" -eq 0 ] && [ "$line" = "service fee: off" ]; then
      echo ""
      echo "service fee off."
      exit 0
    fi
    if [ "$BPS" -gt 0 ] && printf '%s' "$line" | grep -qF "on, $BPS bps, at least $MIN_USDT micro-USDT, to $ADDRESS"; then
      echo ""
      echo "service fee applied. Its first charge is on a user's second top-up."
      exit 0
    fi
    echo "ABORT: the treasury reports a different fee from the one just written."
    exit 1
  fi
  sleep 2
done
echo "ABORT: the treasury logged no \"service fee:\" line within a minute of its restart. Either it did not"
echo "  come back up, or its image predates the service fee and ignores these settings: move its pin to an"
echo "  image with the fee (set-image.sh / \"Deploy stage\" set_images), then run this again."
exit 1
