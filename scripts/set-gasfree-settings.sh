#!/usr/bin/env bash
#
# Write the GasFree rail's settings into an env file, and for mainnet the decided limits too:
#
#   NETWORK=nile    bash scripts/set-gasfree-settings.sh     # .env.testnet: step 2.2 of the Nile rollout
#   NETWORK=mainnet bash scripts/set-gasfree-settings.sh     # .env.mainnet: the mainnet rollout
#
# Only settings that are not secrets. GASFREE_API_KEY and GASFREE_API_SECRET are the relay's
# credentials: this never writes or prints them, and refuses to run until a human has put both in the
# file as plain values, neither blank nor quoted. The key without the network is the one state
# check-cap-invariants.sh refuses, and the network without the key would leave tron-signer on the TRX
# rail while the other two are not.
#
# Nile writes the GasFree block with .env.testnet.example's values. Mainnet writes the block with the values
# the maintainer accepted on 2026-10-02 (the live relay fees were 1.50 USDT to activate and 1.50 per
# transfer) AND the limits of readiness item B4 with the $2.00 redemption fee, except that the payout
# side is the pilot's until the KMS payout key (A2) ships: $50 payouts and a $200 daily payout
# ceiling, and ONE WALLET (a float target of $1,000,000, so every sweep goes to the float). They are
# written together because check-cap-invariants.sh relates them: the fee must cover the relay's transfer
# maximum, and the float target must cover the largest payout plus that fee. test-set-gasfree-
# settings.sh checks every value against .env.testnet.example and .env.mainnet.example.
#
# Nothing is restarted. "Deploy stage (VPS)" applies the nile values and "Mainnet — start the
# treasury" the mainnet ones, and each runs check-cap-invariants.sh first, as this does at the end.
# Once GasFree is on, keep these set for as long as any user has a GasFree address or the GasFree
# float holds USDT (docs/ON-CALL.md, "The GasFree rail").

set -euo pipefail
cd "$(dirname "$0")/.."

NETWORK="${NETWORK:?NETWORK must be set (nile or mainnet)}"

case "$NETWORK" in
  nile)
    ENV_FILE=.env.testnet
    SETTINGS=(
      TRANSFER_RAIL=gasfree
      GASFREE_NETWORK=nile
      GASFREE_API_URL=https://open-test.gasfree.io/nile
      GASFREE_SERVICE_PROVIDER=TKtWbdzEq5ss9vTS9kwRhBp5mXmBfBns3E
      GASFREE_ACTIVATE_FEE_MAX_USDT=1500000
      GASFREE_TRANSFER_FEE_MAX_USDT=500000
      MIN_DEPOSIT_USDT=1000000
      GASFREE_EXPECTED_IMPLEMENTATION=b8eda40b467b45af107f198e94cc2fa1378adf50
      GASFREE_EXPECTED_CONTROLLER_IMPLEMENTATION=2ec1c0ada96ac9c3d6aab8e0c6e18194ed72c441
      # ONE WALLET on stage too (2026-10-05), as on mainnet: a sweep goes to the float while it holds less
      # than this, and to custody after that. $1,000,000 is never reached on Nile, so every sweep goes to
      # the float and custody stays empty. It was $30. check-cap-invariants.sh still needs it to cover
      # the largest payout plus the relay's fee.
      PAYOUT_FLOAT_TARGET_USDT=1000000000000
    )
    ;;
  mainnet)
    ENV_FILE=.env.mainnet
    SETTINGS=(
      TRANSFER_RAIL=gasfree
      GASFREE_NETWORK=mainnet
      GASFREE_API_URL=https://open.gasfree.io/tron
      GASFREE_SERVICE_PROVIDER=TLntW9Z59LYY5KEi9cmwk3PKjQga828ird
      GASFREE_ACTIVATE_FEE_MAX_USDT=2000000
      GASFREE_TRANSFER_FEE_MAX_USDT=2000000
      MIN_DEPOSIT_USDT=5000000
      GASFREE_EXPECTED_IMPLEMENTATION=a3b0edffa1b94e93d297dcc9b6860175e9b537ec
      GASFREE_EXPECTED_CONTROLLER_IMPLEMENTATION=c8b13e3104f8a2d6e915ac132bdeda7faaf84d7d
      # ONE WALLET (accepted 2026-10-05, readiness A2 "One wallet"). A sweep goes to the float while
      # the float holds less than this, and to custody after that. $1,000,000 is never reached (the
      # daily mint cap is $200), so every sweep goes to the float and custody stays empty. This is a
      # switch, not a limit: the float no longer caps what a leaked key can take, because the key on
      # this host (derived from DEPOSIT_MNEMONIC) now holds the whole reserve. To use custody again,
      # put it back to $100. check-cap-invariants.sh still needs it to cover the largest payout plus
      # the relay's fee.
      PAYOUT_FLOAT_TARGET_USDT=1000000000000
      # The PILOT's payout side (accepted 2026-10-04, readiness B4 "Pilot limits"): $50 payouts and a
      # $200 daily ceiling, where B4's decided set has $200 and $1,000. Raise both together, and only
      # after A2 ships.
      # The PILOT's mint caps (accepted 2026-10-05, when mainnet was opened to every account): $100 per
      # deposit and $200 per day, the same as the daily payout ceiling below, where B4's decided set has
      # $1,000 and $2,000. A deposit above the per-transaction cap parks for a human (the user's USDT
      # stays at their address, counted in the reserve, and no CLT is minted), so what is credited in a
      # day can never outgrow what can be paid out. Raise them with the payout side, after A2 ships.
      PER_TX_MINT_CAP_CLT=100000000
      DAILY_MINT_CAP_CLT=200000000
      MAX_REDEMPTION_CLT=50000000
      MIN_REDEMPTION_CLT=25000000
      PER_TX_PAYOUT_CAP_USDT=50000000
      REDEMPTION_FEE_USDT=2000000
      # The rolling 24-hour payout ceiling, the float from the other side. It must stay at or above
      # MAX_REDEMPTION_CLT: treasury-service never pays a redemption that alone exceeds it (payout.rs
      # raises a p1 and skips it), and check-cap-invariants.sh (5b) refuses a set where it does not. $200
      # is four largest payouts, the same ratio as stage's $100 against its $25.
      DAILY_PAYOUT_CAP_CLT=200000000
    )
    ;;
  *)
    echo "ABORT: NETWORK must be nile or mainnet, got '$NETWORK'."
    exit 1
    ;;
esac

if [ ! -f "$ENV_FILE" ]; then
  echo "ABORT: no $ENV_FILE here ($(pwd))."
  exit 1
fi

# Presence and form only: the values are never read into this script, only matched by grep. A value that
# is only blanks, or starts with a quote, counts as not there: compose trims the first to nothing and
# takes the quotes off the second, and the mainnet start refuses both. Only the name is ever printed.
for k in GASFREE_API_KEY GASFREE_API_SECRET; do
  if ! grep -qE "^$k=.+" "$ENV_FILE"; then
    echo "ABORT: $k is not in $ENV_FILE. Put the relay's key and secret in by hand first, unquoted;"
    echo "  this script never writes them. Nothing was changed."
    exit 1
  fi
  if grep -qE "^$k=([[:blank:]]+\$|[\"'])" "$ENV_FILE"; then
    echo "ABORT: $k in $ENV_FILE is blank or quoted: put it in as a plain $k=value line. Nothing was changed."
    exit 1
  fi
done

# One backup, overwritten each run, as set-mint-caps.sh keeps it: every copy holds DEPOSIT_MNEMONIC.
cp -a "$ENV_FILE" "$ENV_FILE.bak"
chmod 600 "$ENV_FILE.bak"
rm -f "$ENV_FILE".bak.*

names=""
for s in "${SETTINGS[@]}"; do names="$names|${s%%=*}"; done
PATTERN="^(${names#|})="

echo "=== before ($ENV_FILE) ==="
grep -E "$PATTERN" "$ENV_FILE" | sed 's/^/    /' || echo "    (none set)"

# A file that does not end in a newline would glue the first appended line onto its last one.
if [ -s "$ENV_FILE" ] && [ -n "$(tail -c1 "$ENV_FILE")" ]; then
  echo >> "$ENV_FILE"
fi

# Replace if present — every copy, so the readers that take the first line and compose agree — and
# append if not. sed -i, as set-mint-caps.sh does: it writes a new file under the same name, which is
# safe because no container mounts the env file; compose reads it when it recreates a service.
for s in "${SETTINGS[@]}"; do
  name="${s%%=*}"
  value="${s#*=}"
  if grep -qE "^$name=" "$ENV_FILE"; then
    sed -i "s#^$name=.*#$name=$value#" "$ENV_FILE"
  else
    printf '%s=%s\n' "$name" "$value" >> "$ENV_FILE"
  fi
done
chmod 600 "$ENV_FILE"

echo ""
echo "=== after ($ENV_FILE) ==="
grep -E "$PATTERN" "$ENV_FILE" | sed 's/^/    /'

echo ""
if [ "$NETWORK" = mainnet ]; then
  echo "Nothing was restarted. Run \"Mainnet — start the treasury\" so that all three services read these values; it runs this check first."
else
  echo "Nothing was restarted. The next stage deploy applies these, and runs this check first."
fi
echo "If the check below fails, $ENV_FILE is already written: fix the value it names, or restore $ENV_FILE.bak."
echo ""
ENV_FILE="$ENV_FILE" bash scripts/check-cap-invariants.sh
