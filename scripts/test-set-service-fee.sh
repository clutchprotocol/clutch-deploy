#!/usr/bin/env bash
# Self-check for set-service-fee.sh's refusals, which all come before the env file is touched or
# anything restarts. CI runs it (test-treasury-scripts.yml) with no docker, no host and no network.
set -euo pipefail
cd "$(dirname "$0")/.."

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts/lib"
cp scripts/set-service-fee.sh scripts/check-cap-invariants.sh "$T/scripts/"
cp scripts/lib/chain.sh "$T/scripts/lib/"
printf 'JWT_SECRET=x\nMIN_DEPOSIT_USDT=1000000\n' > "$T/.env.testnet"
before=$(cat "$T/.env.testnet")

passed=0
failed=0
OP=0x466e50fa1c0609744e0752a5b494511a5bb99006

# refused <name> <text the output must contain> [NAME=value ...]: exit 1, and the env file unchanged.
refused() {
  local name="$1" text="$2" out code=0
  shift 2
  out=$(cd "$T" && env -i PATH="$PATH" "$@" bash scripts/set-service-fee.sh 2>&1) || code=$?
  if [ "$code" -eq 1 ] && printf '%s' "$out" | grep -qF -- "$text" && [ "$(cat "$T/.env.testnet")" = "$before" ]; then
    passed=$((passed + 1))
    echo "ok    $name"
  else
    failed=$((failed + 1))
    echo "FAIL  $name: exit $code, wanted the text: $text"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
}

refused "a percent sign is not basis points" "whole number of basis points" BPS=1%
refused "above 10% is refused" "above 1000" BPS=1001 MIN_USDT=0 ADDRESS=$OP
refused "a TRON address is refused" "not a TRON one" BPS=100 MIN_USDT=500000 ADDRESS=TKtWbdzEq5ss9vTS9kwRhBp5mXmBfBns3E
refused "a minimum in dollars is refused" "whole number of micro-USDT" BPS=100 MIN_USDT=0.50 ADDRESS=$OP
refused "a minimum at the deposit minimum is refused before writing" "is not below MIN_DEPOSIT_USDT" BPS=100 MIN_USDT=1000000 ADDRESS=$OP
refused "an unknown chain is refused" "" CHAIN=moon BPS=0

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
