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

# after_lists <count> <name>...: the "=== after" listing of the last run, up to its blank line, holds exactly
# <count> settings and they are these names. A name set twice in the file is listed twice, so each name is
# counted once. This ties the lists below to what the writer writes: a setting added to the writer and not
# to them, or the other way round, changes the count or the names.
after_lists() {
  local want="$1" got
  shift
  got=$(printf '%s\n' "$out" | sed -n '/^=== after/,/^$/p' | sed -e '1d' -e '/^$/d' -e 's/^ *//' -e 's/=.*//' | sort -u)
  [ "$(printf '%s\n' "$got" | wc -l)" -eq "$want" ] && [ "$got" = "$(printf '%s\n' "$@" | sort)" ]
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
check "the writer says the file is already written if the check fails" said "is already written"
# The fixture sets one maximum twice, so the listing has 11 lines: it is the 10 NAMES that are counted.
check "the after listing has exactly 10 settings on nile" after_lists 10 $NILE_NAMES

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

# 4. A network that is neither: refused, and nothing written. The file holds a valid key pair, so a
#    writer that took the word for a network would write it and leave a backup.
printf '%s\n' GASFREE_API_KEY=key-marker-7f3a GASFREE_API_SECRET=secret-marker-9c1d > "$T/.env"
cp "$T/.env" "$T/before"
rm -f "$T/.env.bak"
run shasta
check "an unknown network: refused" eval '[ "$code" -eq 1 ] && said "NETWORK must be nile or mainnet" && cmp -s "$T/.env" "$T/before" && [ ! -e "$T/.env.bak" ]'

# ---- mainnet (.env.mainnet): the GasFree block AND the decided limits ---------------------------

# 5. A .env.mainnet as the maintainer left it: the key pair, stage-like limits (one twice), an
#    unrelated setting, no newline at the end. The stage .env beside it must never change. It holds a
#    key pair of its own, so a writer that wrote to it by mistake would change it, not refuse.
rm -f "$T/.env" "$T/.env.bak"
printf '%s\n' STAGE_MARK=untouched GASFREE_API_KEY=stage-key-marker GASFREE_API_SECRET=stage-secret-marker > "$T/.env"
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
check "mainnet: the writer says to run the start workflow" said 'Run "Mainnet — start the treasury"'
# The fixture sets one cap twice, so the listing has 18 lines: it is the 17 NAMES that are counted.
check "mainnet: the after listing has exactly 17 settings" after_lists 17 $MAINNET_NAMES
cp "$T/.env.mainnet" "$T/mainnet-after-first"
run mainnet
check "mainnet: a second run changes nothing" eval '[ "$code" -eq 0 ] && cmp -s "$T/.env.mainnet" "$T/mainnet-after-first"'

# 6. No key in .env.mainnet: refused, and the file untouched.
printf '%s\n' GASFREE_API_SECRET=secret-marker-9c1d > "$T/.env.mainnet"
cp "$T/.env.mainnet" "$T/mainnet-before"
rm -f "$T/.env.mainnet.bak"
run mainnet
check "mainnet: no GASFREE_API_KEY: refused, nothing written" eval '[ "$code" -eq 1 ] && said "GASFREE_API_KEY is not in .env.mainnet" && cmp -s "$T/.env.mainnet" "$T/mainnet-before" && [ ! -e "$T/.env.mainnet.bak" ]'

# 7. A key that is only blanks, or a secret in quotes: refused, and the file untouched. Compose trims the
#    one to nothing and takes the quotes off the other, and the start refuses both.
printf '%s\n' "GASFREE_API_KEY=   " GASFREE_API_SECRET=secret-marker-9c1d > "$T/.env.mainnet"
cp "$T/.env.mainnet" "$T/mainnet-before"
rm -f "$T/.env.mainnet.bak"
run mainnet
check "mainnet: a blank GASFREE_API_KEY: refused, nothing written" eval '[ "$code" -eq 1 ] && said "GASFREE_API_KEY in .env.mainnet is blank or quoted" && cmp -s "$T/.env.mainnet" "$T/mainnet-before" && [ ! -e "$T/.env.mainnet.bak" ]'
printf '%s\n' GASFREE_API_KEY=key-marker-7f3a 'GASFREE_API_SECRET="x"' > "$T/.env.mainnet"
cp "$T/.env.mainnet" "$T/mainnet-before"
rm -f "$T/.env.mainnet.bak"
run mainnet
check "mainnet: a quoted GASFREE_API_SECRET: refused, nothing written" eval '[ "$code" -eq 1 ] && said "GASFREE_API_SECRET in .env.mainnet is blank or quoted" && cmp -s "$T/.env.mainnet" "$T/mainnet-before" && [ ! -e "$T/.env.mainnet.bak" ]'

# 8. A nile run never touches .env.mainnet (which holds a key pair of its own, so a writer that wrote to
#    it by mistake would change it, not refuse), and what a run writes and its backup are mode 600
#    whatever the mode of the file was before: the fixtures are made 644 first. The nile modes are read
#    right after the nile run, the mainnet modes right after the mainnet run.
printf '%s\n' MAINNET_MARK=untouched GASFREE_API_KEY=main-key-marker GASFREE_API_SECRET=main-secret-marker > "$T/.env.mainnet"
cp "$T/.env.mainnet" "$T/mainnet-before"
printf '%s\n' GASFREE_API_KEY=key-marker-7f3a GASFREE_API_SECRET=secret-marker-9c1d > "$T/.env"
chmod 644 "$T/.env" "$T/.env.mainnet"
rm -f "$T/.env.bak" "$T/.env.mainnet.bak"
run nile
check "nile never touches .env.mainnet" eval '[ "$code" -eq 0 ] && cmp -s "$T/.env.mainnet" "$T/mainnet-before" && [ ! -e "$T/.env.mainnet.bak" ]'
nile_modes=$(stat -c %a "$T/.env" "$T/.env.bak" 2>&1 | tr '\n' ' ') || true
run mainnet
mainnet_modes=$(stat -c %a "$T/.env.mainnet" "$T/.env.mainnet.bak" 2>&1 | tr '\n' ' ') || true
check "the written files and their backups are mode 600" eval '[ "$code" -eq 0 ] && [ "$nile_modes" = "600 600 " ] && [ "$mainnet_modes" = "600 600 " ]'

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
