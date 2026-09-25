#!/usr/bin/env bash
# Self-check for check-cap-invariants.sh: each GasFree relationship it guards, by its exit code and by
# the line it prints. CI runs this (test-treasury-scripts.yml) with no .env, no docker, no network.
#
# The checker reads .env from its own repository root, so every case runs a copy of it from a temp
# directory that has none, and passes the values in the environment, which the checker reads first.
set -euo pipefail
cd "$(dirname "$0")/.."

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts"
cp scripts/check-cap-invariants.sh "$T/scripts/"

passed=0
failed=0

# check <name> <expected exit code> <text the output must contain> [NAME=value ...]
check() {
  local name="$1" want="$2" text="$3" out code=0
  shift 3
  out=$(env -i PATH="$PATH" "$@" bash "$T/scripts/check-cap-invariants.sh" 2>&1) || code=$?
  if [ "$code" -eq "$want" ] && printf '%s' "$out" | grep -qF -- "$text"; then
    passed=$((passed + 1))
    echo "ok    $name"
  else
    failed=$((failed + 1))
    echo "FAIL  $name: exit $code (wanted $want), wanted the text: $text"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
}

# A complete Nile set, as the rollout plan's Task 10 writes it.
NILE=(
  GASFREE_NETWORK=nile
  GASFREE_API_URL=https://open-test.gasfree.io/nile
  GASFREE_API_KEY=key-marker-7f3a
  GASFREE_API_SECRET=secret-marker-9c1d
  GASFREE_SERVICE_PROVIDER=TKtWbdzEq5ss9vTS9kwRhBp5mXmBfBns3E
  GASFREE_ACTIVATE_FEE_MAX_USDT=1500000
  GASFREE_TRANSFER_FEE_MAX_USDT=500000
  MIN_DEPOSIT_USDT=1000000
  GASFREE_EXPECTED_IMPLEMENTATION=b8eda40b467b45af107f198e94cc2fa1378adf50
  GASFREE_EXPECTED_CONTROLLER_IMPLEMENTATION=2ec1c0ada96ac9c3d6aab8e0c6e18194ed72c441
  PAYOUT_FLOAT_TARGET_USDT=30000000
)

check "GasFree off: the caps alone, as before" 0 "All invariants hold"
check "a complete Nile set holds" 0 "the redemption fee covers a GasFree payout's relay fee" "${NILE[@]}" TRANSFER_RAIL=gasfree
check "the float target covers the largest payout" 0 "the payout float fills far enough for the largest payout" "${NILE[@]}"
check "a trailing slash on the relay URL is the same URL" 0 "All invariants hold" "${NILE[@]}" GASFREE_API_URL=https://open-test.gasfree.io/nile/
check "the redemption fee below the transfer maximum" 1 "is below GASFREE_TRANSFER_FEE_MAX_USDT" "${NILE[@]}" REDEMPTION_FEE_USDT=400000
check "a zero maximum" 1 "GASFREE_TRANSFER_FEE_MAX_USDT is zero" "${NILE[@]}" GASFREE_TRANSFER_FEE_MAX_USDT=0
check "a maximum that is not a whole number" 1 "GASFREE_ACTIVATE_FEE_MAX_USDT must be a positive integer" "${NILE[@]}" GASFREE_ACTIVATE_FEE_MAX_USDT=1.5
check "the signer's API key missing" 1 "GASFREE_API_KEY is not set while GASFREE_NETWORK is" "${NILE[@]}" GASFREE_API_KEY=
check "the service provider missing" 1 "GASFREE_SERVICE_PROVIDER is not set while GASFREE_NETWORK is" "${NILE[@]}" GASFREE_SERVICE_PROVIDER=
check "the other network's relay URL" 1 "needs https://open-test.gasfree.io/nile" "${NILE[@]}" GASFREE_API_URL=https://open.gasfree.io/tron
check "an unknown network" 1 "GASFREE_NETWORK must be nile or mainnet" "${NILE[@]}" GASFREE_NETWORK=shasta
check "an implementation that is not 40 hex" 1 "GASFREE_EXPECTED_IMPLEMENTATION must be 40 hex characters" "${NILE[@]}" GASFREE_EXPECTED_IMPLEMENTATION=b8eda40b
check "the float target below the largest payout" 1 "PAYOUT_FLOAT_TARGET_USDT is below the largest payout plus its relay fee" "${NILE[@]}" PAYOUT_FLOAT_TARGET_USDT=20000000
check "TRANSFER_RAIL=gasfree without GasFree settings" 1 "TRANSFER_RAIL=gasfree needs GASFREE_NETWORK" TRANSFER_RAIL=gasfree
check "an unknown TRANSFER_RAIL" 1 "TRANSFER_RAIL must be trx or gasfree" TRANSFER_RAIL=gasfee

# The key and the secret are never printed, whatever else happens.
out=$(env -i PATH="$PATH" "${NILE[@]}" bash "$T/scripts/check-cap-invariants.sh" 2>&1 || true)
if printf '%s' "$out" | grep -qE 'key-marker-7f3a|secret-marker-9c1d'; then
  failed=$((failed + 1))
  echo "FAIL  the API key and secret never appear in the output"
else
  passed=$((passed + 1))
  echo "ok    the API key and secret never appear in the output"
fi

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
