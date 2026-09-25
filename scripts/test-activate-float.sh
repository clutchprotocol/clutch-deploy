#!/usr/bin/env bash
# Self-check for activate-float.sh's decision, can_activate: whether the reserve's surplus pays for the
# GasFree float's one-time activation. CI runs it (test-treasury-scripts.yml). Nothing is activated:
# sourced, the script only defines its functions.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=activate-float.sh
source scripts/activate-float.sh

passed=0
failed=0

# check <name> <expected exit code> <text> <status> <age s> <custody_reported> <ledger_liability> <owed> <activate max> <transfer max>
check() {
  local name="$1" want="$2" text="$3" out code=0
  shift 3
  out=$(can_activate "$@" 2>&1) || code=$?
  if [ "$code" -eq "$want" ] && printf '%s' "$out" | grep -qF -- "$text"; then
    passed=$((passed + 1))
    echo "ok    $name"
  else
    failed=$((failed + 1))
    echo "FAIL  $name: exit $code (wanted $want), wanted the text: $text"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
}

check "a fresh ok run with enough surplus" 0 "the surplus is 3000000 micro-USDT; activation may cost up to 2000000" ok 600 10000000 7000000 0 1500000 500000
check "a surplus exactly the most it may cost" 0 "the surplus is 2000000 micro-USDT" ok 600 9000000 7000000 0 1500000 500000
check "a surplus one micro-USDT short" 1 "the surplus is 1999999 micro-USDT; activation may cost up to 2000000" ok 600 8999999 7000000 0 1500000 500000
check "a reserve below liability" 1 "the surplus is -1000000 micro-USDT" ok 600 6000000 7000000 0 1500000 500000
check "a mismatch run" 1 "the latest reconciliation run is 'mismatch', not ok" mismatch 600 10000000 7000000 0 1500000 500000
check "no run at all" 1 "the latest reconciliation run is 'none', not ok" none "" "" "" "" 1500000 500000
check "a run over two hours old" 1 "is 7201s old" ok 7201 10000000 7000000 0 1500000 500000
check "a signer without GasFree settings" 1 "the running signer has no GasFree maxima" ok 600 10000000 7000000 0 "" ""
check "a redemption waiting to be paid is still owed" 1 "the surplus is 1000000 micro-USDT; activation may cost up to 2000000" ok 600 10000000 7000000 2000000 1500000 500000
check "an unreadable owed amount" 1 "the latest reconciliation run is unreadable: 'x'" ok 600 10000000 7000000 x 1500000 500000

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
