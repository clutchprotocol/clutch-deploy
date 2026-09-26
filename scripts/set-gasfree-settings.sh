#!/usr/bin/env bash
#
# Write the GasFree rail's settings into stage's .env: step 2.2 of the rollout (clutch-treasury's
# docs/superpowers/plans/2026-09-25-gasfree-rollout.md, Task 10).
#
#   NETWORK=nile bash scripts/set-gasfree-settings.sh
#
# Only the settings that are not secrets, with the values of .env.example's GasFree block
# (test-set-gasfree-settings.sh checks they match). GASFREE_API_KEY and GASFREE_API_SECRET are the
# relay's credentials: this never writes or prints them, and refuses to run until a human has put
# both in .env — the key without the network is the one state check-cap-invariants.sh refuses, and
# the network without the key would leave tron-signer on the TRX rail while the other two are not.
#
# Nothing is restarted. "Deploy stage (VPS)" applies the values, and it runs check-cap-invariants.sh
# first, as this does at the end. Once GasFree is on, keep these set for as long as any user has a
# GasFree address or the GasFree float holds USDT (docs/ON-CALL.md, "The GasFree rail").

set -euo pipefail
cd "$(dirname "$0")/.."

NETWORK="${NETWORK:?NETWORK must be set (nile)}"
if [ "$NETWORK" != "nile" ]; then
  echo "ABORT: this writes the testnet's values only (NETWORK=nile), got '$NETWORK'."
  echo "  Mainnet's maxima, provider and reviewed implementations are not decided yet."
  exit 1
fi

# The Nile values: the same as .env.example's GasFree block.
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
  PAYOUT_FLOAT_TARGET_USDT=30000000
)

if [ ! -f .env ]; then
  echo "ABORT: no .env here ($(pwd))."
  exit 1
fi

# Presence only: the values are never read into this script.
for k in GASFREE_API_KEY GASFREE_API_SECRET; do
  if ! grep -qE "^$k=.+" .env; then
    echo "ABORT: $k is not in .env. Put the relay's key and secret in by hand first, unquoted;"
    echo "  this script never writes them. Nothing was changed."
    exit 1
  fi
done

# One backup, overwritten each run, as set-mint-caps.sh keeps it: every copy holds DEPOSIT_MNEMONIC.
cp -a .env .env.bak
chmod 600 .env.bak
rm -f .env.bak.*

names=""
for s in "${SETTINGS[@]}"; do names="$names|${s%%=*}"; done
PATTERN="^(${names#|})="

echo "=== before ==="
grep -E "$PATTERN" .env | sed 's/^/    /' || echo "    (none set)"

# A file that does not end in a newline would glue the first appended line onto its last one.
if [ -s .env ] && [ -n "$(tail -c1 .env)" ]; then
  echo >> .env
fi

# Replace if present — every copy, so the readers that take the first line and compose agree — and
# append if not. sed -i, as set-mint-caps.sh does: it writes a new file under the same name, which is
# safe because no container mounts .env; compose reads it when it recreates a service.
for s in "${SETTINGS[@]}"; do
  name="${s%%=*}"
  value="${s#*=}"
  if grep -qE "^$name=" .env; then
    sed -i "s#^$name=.*#$name=$value#" .env
  else
    printf '%s=%s\n' "$name" "$value" >> .env
  fi
done
chmod 600 .env

echo ""
echo "=== after ==="
grep -E "$PATTERN" .env | sed 's/^/    /'

echo ""
echo "Nothing was restarted. \"Deploy stage (VPS)\" applies these, and runs this check first:"
echo ""
bash scripts/check-cap-invariants.sh
