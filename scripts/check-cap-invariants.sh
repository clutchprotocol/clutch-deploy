#!/usr/bin/env bash
# Check that the treasury's safety limits are internally consistent.
#
# Readiness item B4. The VALUES are a risk decision — they depend on expected volume and on how
# much a single mistake may cost, and nothing here can pick them for you. The RELATIONSHIPS between
# them are not a decision: get one wrong and a limit either refuses everything or silently protects
# nothing, and both failures are quiet.
#
# Every one of these has a specific failure it prevents, named at the check. Run it before and
# after changing any cap, and on the mainnet set before it ever holds a deposit.
#
#   bash scripts/check-cap-invariants.sh
#
# Reads the live values from .env where set, falling back to the compose defaults, so it checks the
# configuration that will actually run rather than the one in the file you last edited.

set -euo pipefail

cd "$(dirname "$0")/.."

fail=0
note() { printf '  %s\n' "$1"; }
ok()   { printf 'OK    %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1"; fail=1; }

# .env if present, else the compose default. Read by grep rather than sourced: sourcing executes
# whatever is in .env and would pull DEPOSIT_MNEMONIC into this script's environment for no reason.
val() {
  local name="$1" default="$2" v=""
  if [ -f .env ]; then
    v=$(grep -E "^$name=" .env | head -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' || true)
  fi
  printf '%s' "${v:-$default}"
}

usd() { awk -v n="$1" 'BEGIN{printf "$%.2f", n/1000000}'; }

PER_TX_MINT=$(val PER_TX_MINT_CAP_CLT 50000000)
DAILY_MINT=$(val DAILY_MINT_CAP_CLT 500000000)
MAX_REDEEM=$(val MAX_REDEMPTION_CLT 25000000)
MIN_REDEEM=$(val MIN_REDEMPTION_CLT 5000000)
PAYOUT_CAP=$(val PER_TX_PAYOUT_CAP_USDT 25000000)
FEE=$(val REDEMPTION_FEE_USDT 1000000)

for pair in "PER_TX_MINT_CAP_CLT:$PER_TX_MINT" "DAILY_MINT_CAP_CLT:$DAILY_MINT" \
            "MAX_REDEMPTION_CLT:$MAX_REDEEM" "MIN_REDEMPTION_CLT:$MIN_REDEEM" \
            "PER_TX_PAYOUT_CAP_USDT:$PAYOUT_CAP" "REDEMPTION_FEE_USDT:$FEE"; do
  name="${pair%%:*}" v="${pair#*:}"
  case "$v" in
    ''|*[!0-9]*) bad "$name is not a non-negative integer of micro-units: '$v'"; ;;
  esac
done
[ "$fail" -eq 0 ] || { echo ""; echo "Stopping: fix the values above before the relationships mean anything."; exit 1; }

echo "=== values in force ==="
note "per-transaction mint cap   $(usd "$PER_TX_MINT")"
note "daily mint cap             $(usd "$DAILY_MINT")"
note "max redemption (orch)      $(usd "$MAX_REDEEM")"
note "per-tx payout cap (signer) $(usd "$PAYOUT_CAP")"
note "min redemption             $(usd "$MIN_REDEEM")"
note "redemption fee             $(usd "$FEE")"
echo ""
echo "=== invariants ==="

# 1. A single mint has to be able to clear both gates.
if [ "$PER_TX_MINT" -gt "$DAILY_MINT" ]; then
  bad "per-transaction mint cap exceeds the daily cap — no mint could ever clear both, so minting is off"
else
  ok "a single mint can clear both mint gates"
fi

# 2. The two redemption bounds live in different services and are not derived from each other. If
#    the orchestrator allows more than the signer will pay, the difference is a burn nobody can
#    honour: the CLT is destroyed and the payout is refused. This is the one that costs a user money.
if [ "$MAX_REDEEM" -gt "$PAYOUT_CAP" ]; then
  bad "max redemption ($(usd "$MAX_REDEEM")) exceeds the signer's per-transaction payout cap ($(usd "$PAYOUT_CAP"))"
  note "A request between the two burns the CLT and then cannot be paid. Align them."
elif [ "$MAX_REDEEM" -lt "$PAYOUT_CAP" ]; then
  ok "max redemption is within the signer's payout cap"
  note "They differ ($(usd "$MAX_REDEEM") vs $(usd "$PAYOUT_CAP")). Safe, but the headroom does nothing:"
  note "the orchestrator refuses first, so the signer's extra capacity is unreachable."
else
  ok "the two redemption bounds are aligned exactly"
fi

# 3. The treasury refuses a redemption that cannot cover its own fee, and that refusal reaches the
#    user as a bare 502 with no explanation. Every amount between the fee and the minimum fails
#    that way, so the minimum has to sit above the fee.
if [ "$FEE" -ge "$MIN_REDEEM" ]; then
  bad "the redemption fee ($(usd "$FEE")) is not below the minimum redemption ($(usd "$MIN_REDEEM"))"
  note "The smallest allowed redemption would be one the treasury refuses, as an unexplained 502."
else
  ok "the fee is below the minimum redemption"
fi

# 4. A minimum above the maximum refuses every redemption, with no message saying why.
if [ "$MIN_REDEEM" -gt "$MAX_REDEEM" ]; then
  bad "minimum redemption exceeds the maximum — every redemption is refused"
else
  ok "the redemption window is non-empty"
fi

# 5. Not a hard failure, but the ratio is what a user actually experiences.
pct=$(awk -v f="$FEE" -v m="$MIN_REDEEM" 'BEGIN{ if (m>0) printf "%.0f", 100*f/m; else print "0" }')
if [ "$pct" -ge 50 ]; then
  bad "at the minimum redemption the fee is ${pct}% of what the user asked for"
  note "That is the on-chain cost of the payout, not a margin — but it is what they see. Raise the minimum."
elif [ "$pct" -ge 20 ]; then
  ok "fee is ${pct}% of the smallest allowed redemption"
  note "High but defensible. It falls as the amount rises; check the number at a typical amount too."
else
  ok "fee is ${pct}% of the smallest allowed redemption"
fi

echo ""
if [ "$fail" -eq 0 ]; then
  echo "All invariants hold. This says nothing about whether the VALUES are right —"
  echo "see readiness item B4 for what each one bounds."
else
  echo "One or more invariants are broken. Every one of these fails quietly in production:"
  echo "either a limit refuses everything, or it protects nothing, or a burn cannot be paid."
  exit 1
fi
