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

# The process environment first, then .env, then the compose default.
#
# The environment comes first so a cap set can be checked BEFORE the host that will run it exists:
#
#   PER_TX_MINT_CAP_CLT=1000000000 DAILY_MINT_CAP_CLT=2000000000 #     MAX_REDEMPTION_CLT=200000000 PER_TX_PAYOUT_CAP_USDT=200000000 #     MIN_REDEMPTION_CLT=25000000 bash scripts/check-cap-invariants.sh
#
# That is what readiness item B4 needs and could not have: the mainnet numbers are decided long
# before there is a mainnet `.env` to put them in, and "we will check the relationships when we
# provision it" is how a set gets provisioned unchecked.
#
# .env is read by grep rather than sourced: sourcing executes whatever is in it and would pull
# DEPOSIT_MNEMONIC into this script's environment for no reason.
val() {
  local name="$1" default="$2" v=""
  # Indirect expansion, empty if unset — so an exported value wins without `set -u` killing us.
  v="${!name-}"
  if [ -z "$v" ] && [ -f .env ]; then
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

# 6-10. The GasFree rail (clutch-treasury's GasFree design, §6 and §7). Checked while GASFREE_NETWORK is
# set, which is what turns GasFree on in treasury-service and payment-orchestrator. The relay's API key
# and secret are reported as set or missing, never printed.
RAIL=$(val TRANSFER_RAIL trx)
GF_NETWORK=$(val GASFREE_NETWORK "")
case "$RAIL" in
  trx|gasfree) ;;
  *) bad "TRANSFER_RAIL must be trx or gasfree, got '$RAIL' — every treasury service refuses to start" ;;
esac
if [ "$RAIL" = "gasfree" ] && [ -z "$GF_NETWORK" ]; then
  bad "TRANSFER_RAIL=gasfree needs GASFREE_NETWORK and the other GasFree settings — every treasury service refuses to start"
fi
# 7, the other direction. tron-signer turns GasFree on by its API key alone, and then refuses to start
# without GASFREE_NETWORK and the rest. A key left in .env with GasFree off — the probe reads it — would
# stop the signer at the next deploy.
if [ -z "$GF_NETWORK" ] && [ -n "$(val GASFREE_API_KEY "")" ]; then
  bad "GASFREE_API_KEY is set while GASFREE_NETWORK is not — tron-signer would turn GasFree on and refuse to start. Set the whole GasFree block, or comment out GASFREE_API_KEY and GASFREE_API_SECRET"
fi
if [ -n "$GF_NETWORK" ]; then
  echo ""
  echo "=== the GasFree rail (GASFREE_NETWORK=$GF_NETWORK, TRANSFER_RAIL=$RAIL) ==="
  gf_ok=1
  # 6. Whole, positive micro-USDT. A zero maximum signs permits the relay refuses.
  for name in GASFREE_ACTIVATE_FEE_MAX_USDT GASFREE_TRANSFER_FEE_MAX_USDT MIN_DEPOSIT_USDT PAYOUT_FLOAT_TARGET_USDT; do
    v=$(val "$name" "")
    case "$v" in
      ''|*[!0-9]*) bad "$name must be a positive integer of micro-USDT, got '$v'"; gf_ok=0; continue ;;
    esac
    if [ "$v" -eq 0 ]; then
      bad "$name is zero — a zero maximum signs permits the relay refuses, and every sweep stops quietly"
      gf_ok=0
    fi
  done
  # 7. The signer turns GasFree on by its API key, the other two services by the network. One without
  #    the other runs two services with GasFree and one without it.
  for name in GASFREE_API_KEY GASFREE_API_SECRET GASFREE_SERVICE_PROVIDER; do
    if [ -z "$(val "$name" "")" ]; then
      bad "$name is not set while GASFREE_NETWORK is — tron-signer would run without GasFree while the other two run with it"
    fi
  done
  for name in GASFREE_EXPECTED_IMPLEMENTATION GASFREE_EXPECTED_CONTROLLER_IMPLEMENTATION; do
    v=$(val "$name" "")
    v="${v#0x}"
    if ! printf '%s' "$v" | grep -qE '^[0-9a-fA-F]{40}$'; then
      bad "$name must be 40 hex characters (PROBE=gasfree prints the live value), got '$v'"
    fi
  done
  # 8. The relay URL names a network too, and the other network's relay refuses every permit.
  case "$GF_NETWORK" in
    nile)    want_url="https://open-test.gasfree.io/nile" ;;
    mainnet) want_url="https://open.gasfree.io/tron" ;;
    *)       want_url=""; bad "GASFREE_NETWORK must be nile or mainnet, got '$GF_NETWORK'" ;;
  esac
  GF_URL=$(val GASFREE_API_URL "")
  if [ -n "$want_url" ] && [ "${GF_URL%/}" != "$want_url" ]; then
    bad "GASFREE_API_URL is '$GF_URL', but GASFREE_NETWORK=$GF_NETWORK needs $want_url"
  fi
  if [ "$gf_ok" -eq 1 ]; then
    ACT_MAX=$(val GASFREE_ACTIVATE_FEE_MAX_USDT "")
    XFER_MAX=$(val GASFREE_TRANSFER_FEE_MAX_USDT "")
    FLOAT_TARGET=$(val PAYOUT_FLOAT_TARGET_USDT "")
    note "fee held back, first deposit   up to $(usd $((ACT_MAX + XFER_MAX)))"
    note "fee held back, later deposits  up to $(usd "$XFER_MAX")"
    note "minimum after the fee          $(usd "$(val MIN_DEPOSIT_USDT "")")"
    note "payout float target            $(usd "$FLOAT_TARGET")"
    # 9. The design's §7 invariant 1: a GasFree payout's relay fee comes out of the float, and only the
    #    redemption fee pays it back. Below it, every redemption lowers the reserve below supply.
    if [ "$FEE" -lt "$XFER_MAX" ]; then
      bad "the redemption fee ($(usd "$FEE")) is below GASFREE_TRANSFER_FEE_MAX_USDT ($(usd "$XFER_MAX"))"
      note "A GasFree payout may cost the float the whole maximum, so every redemption would leave the reserve short."
    else
      ok "the redemption fee covers a GasFree payout's relay fee"
    fi
    # 10. Sweeps fill the float only while it is below its target. Below the largest payout plus its
    #     relay fee, the largest redemption allowed can wait for ever on a float that stopped filling.
    if [ "$FLOAT_TARGET" -lt $((PAYOUT_CAP + XFER_MAX)) ]; then
      bad "PAYOUT_FLOAT_TARGET_USDT is below the largest payout plus its relay fee ($(usd $((PAYOUT_CAP + XFER_MAX))))"
    else
      ok "the payout float fills far enough for the largest payout"
    fi
  fi
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
