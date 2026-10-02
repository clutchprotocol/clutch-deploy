#!/usr/bin/env bash
# Self-check for set-gasfree-settings.sh, against fixture env files in a temp directory. CI runs it
# (test-treasury-scripts.yml) with no docker and no network: the script restarts nothing, and the
# check-cap-invariants.sh it ends with reads only the env file.
set -euo pipefail
cd "$(dirname "$0")/.."

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts"
cp scripts/set-gasfree-settings.sh scripts/check-cap-invariants.sh "$T/scripts/"

passed=0
failed=0
out=""
code=0
ENVF=.env

# check <name> <condition...>: the condition is a command; its exit status is the verdict.
check() {
  local name="$1"
  shift
  if "$@"; then
    passed=$((passed + 1))
    echo "ok    $name"
  else
    failed=$((failed + 1))
    echo "FAIL  $name"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
}

# run <NETWORK>: the script in $T, with nothing from this environment but PATH.
run() {
  code=0
  out=$(env -i PATH="$PATH" NETWORK="$1" bash "$T/scripts/set-gasfree-settings.sh" 2>&1) || code=$?
}

said() { printf '%s' "$out" | grep -qF -- "$1"; }
has_line() { grep -qxF -- "$1" "$T/$ENVF"; }

# Every setting the script writes must carry the example file's value: the commented line for a
# GasFree setting, the active line for a limit. matches_example <env file> <example file> <name>...
matches_example() {
  local envf="$1" ex="$2" name want got
  shift 2
  for name in "$@"; do
    want=$(sed -n "s/^# $name=//p" "$ex" | head -1)
    [ -n "$want" ] || want=$(sed -n "s/^$name=//p" "$ex" | head -1)
    got=$(sed -n "s/^$name=//p" "$T/$envf" | sort -u)
    if [ -z "$want" ] || [ "$got" != "$want" ]; then
      out="$name: wrote '$got', $ex has '$want'"
      return 1
    fi
  done
}

NILE_NAMES="TRANSFER_RAIL GASFREE_NETWORK GASFREE_API_URL GASFREE_SERVICE_PROVIDER GASFREE_ACTIVATE_FEE_MAX_USDT GASFREE_TRANSFER_FEE_MAX_USDT MIN_DEPOSIT_USDT GASFREE_EXPECTED_IMPLEMENTATION GASFREE_EXPECTED_CONTROLLER_IMPLEMENTATION PAYOUT_FLOAT_TARGET_USDT"
MAINNET_NAMES="$NILE_NAMES PER_TX_MINT_CAP_CLT DAILY_MINT_CAP_CLT MAX_REDEMPTION_CLT MIN_REDEMPTION_CLT PER_TX_PAYOUT_CAP_USDT REDEMPTION_FEE_USDT DAILY_PAYOUT_CAP_CLT"

# ---- nile (the stage .env), unchanged behaviour -------------------------------------------------

# 1. The stage .env as it was left by hand: the key, the secret and the network, one maximum twice at
#    0, a commented line, an unrelated setting, and no newline at the end of the file.
printf '%s\n' UNRELATED=keep-me GASFREE_API_KEY=key-marker-7f3a GASFREE_API_SECRET=secret-marker-9c1d \
  GASFREE_NETWORK=nile GASFREE_ACTIVATE_FEE_MAX_USDT=0 "# GASFREE_API_URL=" GASFREE_ACTIVATE_FEE_MAX_USDT=0 > "$T/.env"
printf 'LAST_LINE=1' >> "$T/.env"
cp "$T/.env" "$T/before"
run nile
check "the half-set block is completed, and the invariants hold" eval '[ "$code" -eq 0 ] && said "All invariants hold"'
check "every value is .env.example's Nile value" matches_example .env .env.example $NILE_NAMES
check "a setting present twice is replaced in both places" eval '[ "$(grep -cx "GASFREE_ACTIVATE_FEE_MAX_USDT=1500000" "$T/.env")" -eq 2 ]'
check "the key, the secret and the other lines are untouched" eval 'has_line GASFREE_API_KEY=key-marker-7f3a && has_line GASFREE_API_SECRET=secret-marker-9c1d && has_line UNRELATED=keep-me && has_line "# GASFREE_API_URL=" && has_line LAST_LINE=1'
check "the key and the secret are never printed" eval '! said key-marker-7f3a && ! said secret-marker-9c1d'
check "the file as it was is kept in .env.bak" cmp -s "$T/.env.bak" "$T/before"

# 2. Run again on its own result: nothing changes.
cp "$T/.env" "$T/after-first"
run nile
check "a second run changes nothing" eval '[ "$code" -eq 0 ] && cmp -s "$T/.env" "$T/after-first"'

# 3. The key missing, or the secret empty: refused, and the file untouched.
printf '%s\n' GASFREE_API_SECRET=secret-marker-9c1d GASFREE_NETWORK=nile > "$T/.env"
cp "$T/.env" "$T/before"
rm -f "$T/.env.bak"
run nile
check "no GASFREE_API_KEY: refused, nothing written" eval '[ "$code" -eq 1 ] && said "GASFREE_API_KEY is not in .env" && cmp -s "$T/.env" "$T/before" && [ ! -e "$T/.env.bak" ]'
printf '%s\n' GASFREE_API_KEY=key-marker-7f3a GASFREE_API_SECRET= > "$T/.env"
cp "$T/.env" "$T/before"
run nile
check "an empty GASFREE_API_SECRET: refused, nothing written" eval '[ "$code" -eq 1 ] && said "GASFREE_API_SECRET is not in .env" && cmp -s "$T/.env" "$T/before"'

# 4. A network that is neither: refused.
run shasta
check "an unknown network: refused" eval '[ "$code" -eq 1 ] && said "NETWORK must be nile or mainnet"'

# ---- mainnet (.env.mainnet): the GasFree block AND the decided limits ---------------------------

# 5. A .env.mainnet as the maintainer left it: the key pair, stage-like limits (one twice), an
#    unrelated setting, no newline at the end. The stage .env beside it must never change.
rm -f "$T/.env" "$T/.env.bak"
printf '%s\n' STAGE_MARK=untouched > "$T/.env"
cp "$T/.env" "$T/stage-before"
printf '%s\n' UNRELATED=keep-me GASFREE_API_KEY=key-marker-7f3a GASFREE_API_SECRET=secret-marker-9c1d \
  PER_TX_MINT_CAP_CLT=50000000 REDEMPTION_FEE_USDT=1000000 PER_TX_MINT_CAP_CLT=50000000 > "$T/.env.mainnet"
printf 'LAST_LINE=1' >> "$T/.env.mainnet"
cp "$T/.env.mainnet" "$T/mainnet-before"
ENVF=.env.mainnet
run mainnet
check "mainnet: the block and the limits are written, and the invariants hold" eval '[ "$code" -eq 0 ] && said "All invariants hold" && said "the redemption fee covers a GasFree payout"'
check "mainnet: every value is .env.mainnet.example's value" matches_example .env.mainnet .env.mainnet.example $MAINNET_NAMES
check "mainnet: a setting present twice is replaced in both places" eval '[ "$(grep -cx "PER_TX_MINT_CAP_CLT=1000000000" "$T/.env.mainnet")" -eq 2 ]'
check "mainnet: the key, the secret and the other lines are untouched, and never printed" eval 'has_line GASFREE_API_KEY=key-marker-7f3a && has_line GASFREE_API_SECRET=secret-marker-9c1d && has_line UNRELATED=keep-me && has_line LAST_LINE=1 && ! said key-marker-7f3a && ! said secret-marker-9c1d'
check "mainnet: the stage .env is never touched" cmp -s "$T/.env" "$T/stage-before"
check "mainnet: the file as it was is kept in .env.mainnet.bak" cmp -s "$T/.env.mainnet.bak" "$T/mainnet-before"
cp "$T/.env.mainnet" "$T/mainnet-after-first"
run mainnet
check "mainnet: a second run changes nothing" eval '[ "$code" -eq 0 ] && cmp -s "$T/.env.mainnet" "$T/mainnet-after-first"'

# 6. No key in .env.mainnet: refused, and the file untouched.
printf '%s\n' GASFREE_API_SECRET=secret-marker-9c1d > "$T/.env.mainnet"
cp "$T/.env.mainnet" "$T/mainnet-before"
rm -f "$T/.env.mainnet.bak"
run mainnet
check "mainnet: no GASFREE_API_KEY: refused, nothing written" eval '[ "$code" -eq 1 ] && said "GASFREE_API_KEY is not in .env.mainnet" && cmp -s "$T/.env.mainnet" "$T/mainnet-before" && [ ! -e "$T/.env.mainnet.bak" ]'

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
