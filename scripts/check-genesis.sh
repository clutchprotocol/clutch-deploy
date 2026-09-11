#!/usr/bin/env bash
# Check the node configs agree on everything the genesis hash covers, before booting them.
#
# Readiness item C1. Eight values are committed into the genesis hash by the ChainInit transaction,
# and peers compare that hash at handshake — so a single character of disagreement between two
# nodes means they cannot peer at all. Today the only thing enforcing that is a comment in
# node1.toml saying the values MUST be byte-identical.
#
# The node asserts some of this at boot, which is the right place for a last line of defence and
# the wrong place to discover it: a genesis mistake found at boot on mainnet is found after the
# chain has been announced.
#
#   bash scripts/check-genesis.sh                    # checks config/node/*.toml
#   MAINNET=1 bash scripts/check-genesis.sh          # also enforces the mainnet-only rules
#
# `authorities` is NOT in the genesis hash — it is per-node config — but a disagreement there is
# just as fatal in a different way: the slot-to-author mapping is `authorities[slot % len]`, so a
# node with a different list rejects blocks the rest of the network accepts. Checked here too.

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG_DIR="${CONFIG_DIR:-config/node}"
fail=0
ok()  { printf 'OK    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=1; }
note(){ printf '      %s\n' "$1"; }

mapfile -t FILES < <(find "$CONFIG_DIR" -maxdepth 1 -name '*.toml' | sort)
if [ "${#FILES[@]}" -eq 0 ]; then
  echo "ABORT: no .toml files in $CONFIG_DIR"
  exit 1
fi
echo "=== checking ${#FILES[@]} node config(s) in $CONFIG_DIR ==="
printf '      %s\n' "${FILES[@]}"
echo ""

# Scalar read. Strips an inline comment, surrounding quotes and whitespace, so `x = 1 # why`
# compares equal to `x = 1`.
get() {
  grep -E "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null | head -1 \
    | cut -d= -f2- | sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    -e 's/^"//' -e 's/"$//'
}

# The authorities array, flattened to one comparable line. Order matters, so it is preserved.
authorities_of() {
  awk '/^[[:space:]]*authorities[[:space:]]*=/{f=1} f{print} f&&/\]/{exit}' "$1" \
    | tr -d ' \t\n"' | sed -e 's/.*authorities=\[//' -e 's/\].*//'
}

# --- the eight genesis-committed values, plus the authority set -------------------------------
echo "=== agreement across nodes ==="
GENESIS_FIELDS="chain_id is_testnet tx_fee ride_request_referrer_fee_bps ride_offer_referrer_fee_bps mint_authority faucet_address faucet_allocation"

# Committed to the genesis hash like the eight above, but added later and carrying a
# `#[serde(default)]` in the node. Absent therefore means the default rather than a mistake, and
# checking them like the others would fail every config written before they existed -- including
# the running testnet, on a script that gates a boot.
#
# They still have to AGREE: two nodes disagreeing about a default and an explicit value have
# different genesis hashes and cannot peer, which is exactly what a defaulted field hides.
OPTIONAL_GENESIS_FIELDS="mint_cosigners=[] mint_threshold=0 ride_auto_release_secs=0"
for field in $GENESIS_FIELDS; do
  first=$(get "${FILES[0]}" "$field")
  if [ -z "$first" ]; then
    bad "$field is missing from ${FILES[0]}"
    continue
  fi
  mismatch=""
  for f in "${FILES[@]:1}"; do
    v=$(get "$f" "$field")
    [ "$v" = "$first" ] || mismatch="$mismatch $(basename "$f")=$v"
  done
  if [ -n "$mismatch" ]; then
    bad "$field disagrees: ${FILES[0]##*/}=$first$mismatch"
    note "The genesis hash covers this. Nodes will fail to peer."
  else
    ok "$field agrees ($first)"
  fi
done

for spec in $OPTIONAL_GENESIS_FIELDS; do
  field="${spec%%=*}"
  default="${spec#*=}"
  first=$(get "${FILES[0]}" "$field" || true)
  [ -n "$first" ] || first="$default"
  mismatch=""
  for f in "${FILES[@]:1}"; do
    v=$(get "$f" "$field" || true)
    [ -n "$v" ] || v="$default"
    [ "$v" = "$first" ] || mismatch="$mismatch $(basename "$f")=$v"
  done
  if [ -n "$mismatch" ]; then
    bad "$field disagrees: ${FILES[0]##*/}=$first$mismatch"
    note "Committed to the genesis hash. An unset value is the default, not a wildcard, so a node"
    note "that omits it and one that sets it are two different chains."
  else
    ok "$field agrees ($first)"
  fi
done

first_auth=$(authorities_of "${FILES[0]}")
auth_mismatch=""
for f in "${FILES[@]:1}"; do
  [ "$(authorities_of "$f")" = "$first_auth" ] || auth_mismatch="$auth_mismatch $(basename "$f")"
done
if [ -n "$auth_mismatch" ]; then
  bad "the authorities list differs in:$auth_mismatch"
  note "Not genesis-committed, but authorities[slot % len] depends on order AND length —"
  note "a node with a different list rejects blocks the others accept."
else
  ok "the authorities list agrees, in the same order"
fi

# --- values that must hold regardless of who agrees -------------------------------------------
echo ""
echo "=== value rules ==="
IS_TESTNET=$(get "${FILES[0]}" is_testnet)
FAUCET_ALLOC=$(get "${FILES[0]}" faucet_allocation)
RBPS=$(get "${FILES[0]}" ride_request_referrer_fee_bps)
OBPS=$(get "${FILES[0]}" ride_offer_referrer_fee_bps)
MINT_AUTH=$(get "${FILES[0]}" mint_authority)
CHAIN_ID=$(get "${FILES[0]}" chain_id)

if [ "$(( RBPS + OBPS ))" -gt 10000 ]; then
  bad "referrer fees sum to $(( RBPS + OBPS )) bps, over 100% — the node refuses to boot on this"
else
  ok "referrer fees sum to $(( RBPS + OBPS )) bps"
fi

# One authority is legal; zero divides by zero computing the step duration, and over 60 truncates
# it to zero so every slot calculation divides by zero after a clean boot.
n_auth=$(printf '%s' "$first_auth" | tr ',' '\n' | grep -c . || true)
if [ "$n_auth" -eq 0 ]; then
  bad "the authority set is empty"
elif [ "$n_auth" -gt 60 ]; then
  bad "$n_auth authorities exceeds the maximum of 60 (step duration is 60/len and truncates to 0)"
else
  ok "$n_auth authorities, within the workable range"
  note "Block cadence is 60/$n_auth = $(( 60 / n_auth ))s per slot. Changing the SIZE changes this."
fi
dupes=$(printf '%s' "$first_auth" | tr ',' '\n' | tr '[:upper:]' '[:lower:]' | grep . | sort | uniq -d || true)
if [ -n "$dupes" ]; then
  bad "an authority appears more than once: $dupes"
  note "It would silently take two slots per round."
else
  ok "no duplicate authorities"
fi

case "$MINT_AUTH" in
  0x*) [ "${#MINT_AUTH}" -eq 42 ] && ok "mint_authority is address-shaped" \
         || bad "mint_authority is not 0x + 40 hex: $MINT_AUTH" ;;
  *)   bad "mint_authority is not set to an 0x address: '$MINT_AUTH'" ;;
esac

# --- mainnet-only ------------------------------------------------------------------------------
echo ""
if [ "${MAINNET:-0}" = "1" ]; then
  echo "=== mainnet rules ==="
  if [ "$IS_TESTNET" != "false" ]; then
    bad "is_testnet is '$IS_TESTNET' — a mainnet genesis must set it false"
  else
    ok "is_testnet is false"
  fi
  if [ "$FAUCET_ALLOC" != "0" ]; then
    bad "faucet_allocation is $FAUCET_ALLOC — a surviving pre-mint destroys the peg"
    note "Every CLT must be minted against a verified deposit. The node also refuses this at boot."
  else
    ok "faucet_allocation is 0, so genesis pre-mints nothing"
  fi
  if [ "$CHAIN_ID" = "2077" ]; then
    bad "chain_id is still 2077, the testnet id — mainnet needs its own"
    note "chain_id binds a signed auth challenge to one chain. Sharing it lets a challenge"
    note "captured on testnet authenticate the same key here."
  else
    ok "chain_id ($CHAIN_ID) differs from the testnet's 2077"
  fi

  # Decided 2026-09-12: three mint authorities, any two must sign. Recorded in
  # clutch-treasury/docs/mainnet-readiness.md item A1. Checked as an exact value rather than
  # "greater than one" because a typo that lowers it is the failure that looks fine.
  MINT_THRESHOLD=$(get "${FILES[0]}" mint_threshold || true)
  [ -n "$MINT_THRESHOLD" ] || MINT_THRESHOLD=0
  COSIGNERS=$(get "${FILES[0]}" mint_cosigners || true)
  if [ -z "$COSIGNERS" ] || [ "$COSIGNERS" = "[]" ]; then
    COSIGNER_COUNT=0
  else
    COSIGNER_COUNT=$(printf '%s' "$COSIGNERS" | tr -cd ',' | wc -c)
    COSIGNER_COUNT=$((COSIGNER_COUNT + 1))
  fi
  if [ "$MINT_THRESHOLD" != "2" ]; then
    bad "mint_threshold is '$MINT_THRESHOLD' — the decision of record is 2 of 3"
    note "A single-signature mint authority means a stolen key mints without limit, and the"
    note "four-eyes rule in treasury-service is off-chain and does not stop it."
  else
    ok "mint_threshold is 2"
  fi
  if [ "$COSIGNER_COUNT" != "2" ]; then
    bad "mint_cosigners lists $COSIGNER_COUNT address(es) — 2 of 3 needs exactly 2 alongside mint_authority"
    note "Three keys total, in three separate places. Three in one account is a 2-of-3 on paper"
    note "and a 1-of-1 in practice."
  else
    ok "mint_cosigners lists 2, making a set of 3"
  fi

  # Decided 2026-09-12: two hours. Long enough for a rider to notice a problem, short enough that
  # a driver is not financing them. Genesis-committed, so it is decided once.
  AUTO_RELEASE=$(get "${FILES[0]}" ride_auto_release_secs || true)
  [ -n "$AUTO_RELEASE" ] || AUTO_RELEASE=0
  if [ "$AUTO_RELEASE" != "7200" ]; then
    bad "ride_auto_release_secs is '$AUTO_RELEASE' — the decision of record is 7200 (2 hours)"
    note "0 leaves a driver with no way to be paid by a rider who simply stops sending RidePay."
    note "A wrong non-zero value is worse than obvious: it silently shifts who the held fare"
    note "belongs to, and it cannot be changed without a new chain."
  else
    ok "ride_auto_release_secs is 7200 (2 hours)"
  fi
else
  echo "=== mainnet rules: SKIPPED ==="
  note "is_testnet=$IS_TESTNET, faucet_allocation=$FAUCET_ALLOC, chain_id=$CHAIN_ID"
  note "mint_threshold=$(get "${FILES[0]}" mint_threshold || true), ride_auto_release_secs=$(get "${FILES[0]}" ride_auto_release_secs || true) (empty means the default)"
  note "Re-run with MAINNET=1 to enforce the mainnet-only rules on this config."
fi

echo ""
if [ "$fail" -eq 0 ]; then
  echo "All checks passed."
else
  echo "Fix the failures above BEFORE booting. A genesis mistake found at boot is found after"
  echo "the chain has been announced, and the eight committed values cannot be changed afterwards"
  echo "without a new genesis."
  exit 1
fi
