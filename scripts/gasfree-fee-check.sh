#!/usr/bin/env bash
#
# Compare the GasFree relay's live fees for one token with the configured maxima. The GasFree
# design's §7: "PROBE=gasfree reports whether the live fee is at or below each configured maximum."
#
#   bash scripts/gasfree-fee-check.sh <token contract> <activate max> <transfer max>  < token list
#
# stdin is the relay's reply to GET /api/v1/config/token/all. Prints one line per fee, and exits 0
# when both are at or below their maximum, 1 when either is above it or cannot be read. No network
# and no .env: PROBE=gasfree pipes the live reply in, and test-gasfree-fee-check.sh a fixture.
set -uo pipefail

TOKEN="$1" ACT_MAX="$2" XFER_MAX="$3"

# One JSON object per line; the token's own object carries its fees.
entry=$(tr '{' '\n' | grep -E "\"tokenAddress\" *: *\"$TOKEN\"" | head -1)
if [ -z "$entry" ]; then
  echo "the relay's token list does not include $TOKEN"
  exit 1
fi

status=0
for check in "activateFee $ACT_MAX GASFREE_ACTIVATE_FEE_MAX_USDT" "transferFee $XFER_MAX GASFREE_TRANSFER_FEE_MAX_USDT"; do
  set -- $check
  live=$(printf '%s' "$entry" | sed -n "s/.*\"$1\" *: *\([0-9][0-9]*\).*/\1/p")
  if [ -z "$live" ]; then
    echo "$1: not in the relay's reply"
    status=1
  elif [ "$live" -le "$2" ]; then
    echo "$1: live $live, at or below $3 $2 -- OK"
  else
    echo "$1: live $live, ABOVE $3 $2 -- the relay refuses permits at this maximum; read docs/ON-CALL.md before raising it"
    status=1
  fi
done
exit "$status"
