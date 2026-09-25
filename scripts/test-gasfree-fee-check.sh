#!/usr/bin/env bash
# Self-check for gasfree-fee-check.sh, against fixtures shaped like the relay's reply to
# GET /api/v1/config/token/all. CI runs it (test-treasury-scripts.yml): no network, no .env.
set -euo pipefail
cd "$(dirname "$0")/.."

USDT=TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf

# reply <activateFee> <transferFee>: the token list as the relay sends it, compact, with another token
# listed first whose fees must never be read as ours.
reply() {
  printf '{"code":200,"reason":null,"message":null,"data":{"tokens":[{"tokenAddress":"TXLAQ63Xg1NAzckPwKHvzw7CSEmLMEqcdj","activateFee":9000000,"transferFee":9000000,"supported":true,"symbol":"USDT","decimal":6},{"tokenAddress":"%s","createdAt":"2024-06-01T00:00:00Z","activateFee":%s,"transferFee":%s,"supported":true,"symbol":"USDT","decimal":6}]}}' "$USDT" "$1" "$2"
}

passed=0
failed=0

# check <name> <expected exit code> <text the output must contain> <stdin> <token> <activate max> <transfer max>
check() {
  local name="$1" want="$2" text="$3" input="$4" out code=0
  shift 4
  out=$(printf '%s' "$input" | bash scripts/gasfree-fee-check.sh "$@" 2>&1) || code=$?
  if [ "$code" -eq "$want" ] && printf '%s' "$out" | grep -qF -- "$text"; then
    passed=$((passed + 1))
    echo "ok    $name"
  else
    failed=$((failed + 1))
    echo "FAIL  $name: exit $code (wanted $want), wanted the text: $text"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
}

check "Nile's live fees under the plan's maxima" 0 "transferFee: live 300000, at or below GASFREE_TRANSFER_FEE_MAX_USDT 500000" "$(reply 1000000 300000)" "$USDT" 1500000 500000
check "a fee exactly at its maximum is allowed" 0 "activateFee: live 1500000, at or below GASFREE_ACTIVATE_FEE_MAX_USDT 1500000" "$(reply 1500000 500000)" "$USDT" 1500000 500000
check "a transfer fee above its maximum" 1 "transferFee: live 600000, ABOVE GASFREE_TRANSFER_FEE_MAX_USDT 500000" "$(reply 1000000 600000)" "$USDT" 1500000 500000
check "an activation fee above its maximum" 1 "activateFee: live 2000000, ABOVE GASFREE_ACTIVATE_FEE_MAX_USDT 1500000" "$(reply 2000000 300000)" "$USDT" 1500000 500000
check "another token's fees are not ours" 0 "activateFee: live 1000000, at or below" "$(reply 1000000 300000)" "$USDT" 1500000 500000
check "a token the relay does not list" 1 "does not include TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t" "$(reply 1000000 300000)" TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t 1500000 500000
check "spaces after the colons" 0 "transferFee: live 300000, at or below" '{"data":{"tokens":[{"tokenAddress": "TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf", "activateFee": 1000000, "transferFee": 300000}]}}' "$USDT" 1500000 500000
check "an empty reply" 1 "does not include TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf" "" "$USDT" 1500000 500000

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
