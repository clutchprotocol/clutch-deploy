#!/usr/bin/env bash
# Self-check that the operator scripts and workflows are chain-aware. The scripts act on live
# containers, so CI cannot run them; this reads them for what would quietly undo the switch: a stage
# container or project name left in a script, a script that does not use the chain helper, a workflow
# without the choice, without the longer typed word for mainnet, that never tells the host which chain,
# or an activate-float.sh that would print the account xpub into a public log.
set -euo pipefail
cd "$(dirname "$0")/.."

passed=0
failed=0
pass() { passed=$((passed + 1)); echo "ok    $1"; }
fail() { failed=$((failed + 1)); echo "FAIL  $1"; }

for s in halt-minting resume-minting set-mint-caps activate-float sweep-address backup-treasury-db; do
  f="scripts/$s.sh"
  if grep -q 'clutch-stage' "$f"; then fail "$s.sh names no stage container or project"; else pass "$s.sh names no stage container or project"; fi
  if grep -q 'lib/chain.sh' "$f" && grep -q 'chain_select' "$f"; then
    pass "$s.sh takes its names from the chain helper"
  else
    fail "$s.sh takes its names from the chain helper"
  fi
done

# <workflow>:<the word it asks for on stage>
for pair in halt-minting:halt resume-minting:resume set-mint-caps:set activate-float:activate sweep-address:sweep; do
  w="${pair%%:*}" word="${pair##*:}"
  f=".github/workflows/$w.yml"
  if grep -q '^      chain:' "$f" && grep -q '^          - mainnet' "$f"; then
    pass "$w.yml offers the chain choice"
  else
    fail "$w.yml offers the chain choice"
  fi
  if grep -q "want=\"$word mainnet\"" "$f"; then
    pass "$w.yml asks for '$word mainnet' on mainnet"
  else
    fail "$w.yml asks for '$word mainnet' on mainnet"
  fi
  # CHAIN must be written to the file the host sources: a name in the `for v in ... ;` list of the
  # three workflows that already pass inputs, or the printf of the two that did not. The bare word
  # CHAIN is not enough: the confirmation step has it too, and a run that never tells the host acts
  # on stage whatever the maintainer chose.
  if grep -qE "for v in [A-Z_ ]*CHAIN;|printf 'CHAIN=%q" "$f" && grep -q 'set -a' "$f"; then
    pass "$w.yml passes CHAIN to the host"
  else
    fail "$w.yml passes CHAIN to the host"
  fi
done

f=.github/workflows/backup-treasury-db.yml
if grep -q 'chain_select mainnet' "$f" && grep -q 'CHAIN=mainnet bash scripts/backup-treasury-db.sh' "$f"; then
  pass "backup-treasury-db.yml backs up the mainnet treasury once it exists"
else
  fail "backup-treasury-db.yml backs up the mainnet treasury once it exists"
fi

# The signer's /internal/xpub reply holds account_xpub. activate-float.sh prints that reply, and with
# CHAIN=mainnet the mainnet xpub would reach a public log, where anyone can derive every deposit
# address from it. The word is in the script only in the filter that removes it.
if grep -q 'account_xpub' scripts/activate-float.sh; then
  pass "activate-float.sh does not print the account xpub"
else
  fail "activate-float.sh does not print the account xpub"
fi

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
