#!/usr/bin/env bash
# Self-check that the operator scripts and workflows are chain-aware, and that they keep what must not
# be public out of the run logs. The scripts act on live containers, so CI cannot run them; this reads
# them for what would quietly undo the switch: a stage container or project name left in a script, a
# script that does not use the chain helper, a workflow without the choice, without the longer typed
# word for mainnet, or that never tells the host which chain (in the confirmation step or in the SSH
# step: a missing line there makes a "halt mainnet" run halt stage).
#
# It also reads for the guards that protect a public log: the account xpub is never printed
# (activate-float.sh and fund-float.sh filter it out, provision-treasury-secrets.sh does not print
# it); sweep-address is stage only (no chain choice in its workflow, and the script refuses mainnet);
# set-mint-caps.sh refuses a mainnet treasury that is not running and prints no compose output on
# mainnet. And for three more things: the backup honours an empty BACKUP_REMOTE, removes a partial
# dump, and its nightly workflow says when the mainnet treasury is stopped; the two typed words of
# the settings writer and of the mainnet start are still asked for; and the four workflows that write
# .env.mainnet share one concurrency group.
set -euo pipefail
cd "$(dirname "$0")/.."

passed=0
failed=0
pass() { passed=$((passed + 1)); echo "ok    $1"; }
fail() { failed=$((failed + 1)); echo "FAIL  $1"; }

for s in halt-minting resume-minting set-mint-caps activate-float sweep-address backup-treasury-db \
         mint-intent redrive-mint reverse-mint close-repaid-deposit restore-treasury-db verify-restored-ledger; do
  f="scripts/$s.sh"
  if grep -q 'clutch-stage' "$f"; then fail "$s.sh names no stage container or project"; else pass "$s.sh names no stage container or project"; fi
  if grep -q 'lib/chain.sh' "$f" && grep -q 'chain_select' "$f"; then
    pass "$s.sh takes its names from the chain helper"
  else
    fail "$s.sh takes its names from the chain helper"
  fi
done

# <workflow>:<the word it asks for on stage>. sweep-address is not in this list: it is stage only (below).
for pair in halt-minting:halt resume-minting:resume set-mint-caps:set activate-float:activate \
            mint-intent-create:create mint-intent-approve:approve redrive-mint:redrive reverse-mint:reverse \
            close-repaid-deposit:close rehearse-restore:rehearse; do
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
  # two workflows that already pass inputs, or the printf of the two that did not. The bare word
  # CHAIN is not enough: the confirmation step has it too, and a run that never tells the host acts
  # on stage whatever the maintainer chose.
  if grep -qE "for v in [A-Z_ ]*CHAIN;|printf 'CHAIN=%q" "$f" && grep -q 'set -a' "$f"; then
    pass "$w.yml passes CHAIN to the host"
  else
    fail "$w.yml passes CHAIN to the host"
  fi
  # The step that checks the confirmation and the SSH step each take CHAIN from the input, so the line
  # is there twice. A missing line in the SSH step writes CHAIN='' into the file the host sources, and
  # a "halt mainnet" run would halt stage.
  if [ "$(grep -cF 'CHAIN: ${{ inputs.chain }}' "$f")" -ge 2 ]; then
    pass "$w.yml sets CHAIN in the confirmation step and in the SSH step"
  else
    fail "$w.yml sets CHAIN in the confirmation step and in the SSH step"
  fi
done

f=.github/workflows/backup-treasury-db.yml
if grep -q 'chain_select mainnet' "$f" && grep -q 'CHAIN=mainnet bash scripts/backup-treasury-db.sh' "$f"; then
  pass "backup-treasury-db.yml backs up the mainnet treasury once it exists"
else
  fail "backup-treasury-db.yml backs up the mainnet treasury once it exists"
fi

# sweep-address is stage only. Its workflow prints the typed address into the public run log before
# anything on the host could refuse it, so the workflow has no chain choice. The script refuses mainnet
# too, as a second guard.
if grep -q '^      chain:' .github/workflows/sweep-address.yml; then
  fail "sweep-address.yml is stage only: it has no chain choice"
else
  pass "sweep-address.yml is stage only: it has no chain choice"
fi
if grep -q 'ABORT: sweeping a mainnet deposit address' scripts/sweep-address.sh; then
  pass "sweep-address.sh refuses mainnet"
else
  fail "sweep-address.sh refuses mainnet"
fi

# An empty BACKUP_REMOTE means "no upload": the restore rehearsal passes one. `${BACKUP_REMOTE:-...}`
# reads it as unset and would upload to the real remote; `${BACKUP_REMOTE-...}` does not.
if grep -qF 'BACKUP_REMOTE="${BACKUP_REMOTE-' scripts/backup-treasury-db.sh; then
  pass "backup-treasury-db.sh honours an empty BACKUP_REMOTE"
else
  fail "backup-treasury-db.sh honours an empty BACKUP_REMOTE"
fi
# A failed dump leaves the small file the redirect created, and the retention counts files.
if grep -qF 'the partial file was removed' scripts/backup-treasury-db.sh; then
  pass "backup-treasury-db.sh removes a partial dump"
else
  fail "backup-treasury-db.sh removes a partial dump"
fi
# A mainnet database container that exists and is stopped would otherwise fail inside pg_dump every night.
if grep -qF 'exists but is not running: NOT backed up' .github/workflows/backup-treasury-db.yml; then
  pass "backup-treasury-db.yml says when the mainnet treasury exists but is not running"
else
  fail "backup-treasury-db.yml says when the mainnet treasury exists but is not running"
fi

# The signer's /internal/xpub reply holds account_xpub. activate-float.sh and fund-float.sh print that
# reply, and with the mainnet signer the xpub would reach a public log, where anyone can derive every
# deposit address from it. Both must drop that line. The check matches the filter itself, not the bare
# word: the word also stands in comments, and a comment would pass for a filter that is gone.
for s in activate-float fund-float; do
  if grep -qF "grep -v '\"account_xpub\"'" "scripts/$s.sh"; then
    pass "$s.sh does not print the account xpub"
  else
    fail "$s.sh does not print the account xpub"
  fi
done
# provision-treasury-secrets.sh reads the xpub to compare it and to write it to the env file, and used
# to print it in its summary. No line of it may print it again ("account_xpub = <value>").
if grep -q 'account_xpub = ' scripts/provision-treasury-secrets.sh; then
  fail "provision-treasury-secrets.sh does not print the account xpub"
else
  pass "provision-treasury-secrets.sh does not print the account xpub"
fi

# The two typed words that guard a write to the mainnet env file, and the start of the mainnet treasury.
if grep -qF 'want="gasfree mainnet"' .github/workflows/set-gasfree-settings.yml; then
  pass "set-gasfree-settings.yml asks for 'gasfree mainnet' on mainnet"
else
  fail "set-gasfree-settings.yml asks for 'gasfree mainnet' on mainnet"
fi
if grep -qF '!= "START MAINNET TREASURY"' .github/workflows/mainnet-treasury-up.yml; then
  pass "mainnet-treasury-up.yml asks for the typed word"
else
  fail "mainnet-treasury-up.yml asks for the typed word"
fi

# They all write or read .env or .env.mainnet, so they must queue and never run together. The line is
# matched at its start, so the text of a comment cannot stand in for it.
shared=1
for w in provision-treasury-secrets set-gasfree-settings set-mint-caps mainnet-treasury-up; do
  grep -q '^  group: env-file-writers' ".github/workflows/$w.yml" || shared=0
done
if [ "$shared" -eq 1 ]; then
  pass "the four workflows that write .env.mainnet share one concurrency group"
else
  fail "the four workflows that write .env.mainnet share one concurrency group"
fi

# set-mint-caps.sh on mainnet: it must not start the treasury service alone, with no database, and it
# must not print compose's output, which can quote a line of .env.mainnet into the public log.
if grep -qF 'is not running. Start the mainnet treasury first' scripts/set-mint-caps.sh; then
  pass "set-mint-caps.sh refuses a mainnet treasury that is not running"
else
  fail "set-mint-caps.sh refuses a mainnet treasury that is not running"
fi
if grep -qF 'The output is not printed, because the log is public' scripts/set-mint-caps.sh; then
  pass "set-mint-caps.sh does not print compose output on mainnet"
else
  fail "set-mint-caps.sh does not print compose output on mainnet"
fi

# The manual mint tools on mainnet. Their workflow logs are public, so a user's address must never reach
# one whole: every place that prints one goes through the cutting helpers (chain_mask, chain_mask_sql, and
# show_resp for the treasury's JSON reply, which names the beneficiary). The check matches the call
# itself, not the bare word, which also stands in comments.
for pair in "mint-intent:chain_mask_sql beneficiary" "mint-intent:chain_mask \"\$BENEFICIARY\"" "mint-intent:show_resp \"\$RESP\"" \
            "redrive-mint:chain_mask_sql i.beneficiary" "close-repaid-deposit:chain_mask_sql clt_address" \
            "close-repaid-deposit:chain_mask_sql tron_tx_id" "close-repaid-deposit:chain_mask \"\$BENEFICIARY\""; do
  s="${pair%%:*}" needle="${pair#*:}"
  if grep -qF -- "$needle" "scripts/$s.sh"; then
    pass "$s.sh cuts a user's address with '$needle'"
  else
    fail "$s.sh cuts a user's address with '$needle'"
  fi
done
# And no query of them selects the column bare.
if grep -qE '^[[:space:]]*(-c )?"select id, beneficiary,|i\.beneficiary,$|select id, status, amount_usdt, received_usdt, clt_address' \
     scripts/mint-intent.sh scripts/redrive-mint.sh scripts/close-repaid-deposit.sh; then
  fail "no mint tool selects a user's address bare"
else
  pass "no mint tool selects a user's address bare"
fi

# `approve` takes `needs_manual`: the treasury accepts it (a deposit over the per-transaction cap lands
# there, and the way out is to raise the cap and approve again), and the alert says to use this tool.
if grep -qF '"$STATUS" != "needs_manual"' scripts/mint-intent.sh; then
  pass "mint-intent.sh approves an intent parked in needs_manual"
else
  fail "mint-intent.sh approves an intent parked in needs_manual"
fi
# What reaches SQL is checked first: an intent id for its shape, a mainnet beneficiary for being an
# address, a close id for hex, and a reversal's reason for the dollar sign that would end its quoting.
for pair in "mint-intent:UUID_RE" "mint-intent:on mainnet BENEFICIARY must be 0x" "reverse-mint:INTENT_ID is not a UUID" \
            "reverse-mint:REASON may not contain a dollar sign" "close-repaid-deposit:DEPOSIT_ID may hold only hex digits and dashes"; do
  s="${pair%%:*}" needle="${pair#*:}"
  if grep -qF -- "$needle" "scripts/$s.sh"; then
    pass "$s.sh checks its input: '$needle'"
  else
    fail "$s.sh checks its input: '$needle'"
  fi
done
# The confirmation is read from the environment in every one of the five, never interpolated into the
# script body (a `${{ inputs.confirm }}` inside a run block is shell text).
for w in mint-intent-create mint-intent-approve redrive-mint reverse-mint close-repaid-deposit rehearse-restore; do
  if grep -qF 'CONFIRM: ${{ inputs.confirm }}' ".github/workflows/$w.yml" && ! grep -qE 'if \[ "\$\{\{ inputs\.confirm' ".github/workflows/$w.yml"; then
    pass "$w.yml reads the confirmation from the environment"
  else
    fail "$w.yml reads the confirmation from the environment"
  fi
done

# The restore rehearsal on mainnet. The reconciliation runs through the chosen treasury's own compose
# definition (chain_compose), the restore passes the chain on to restore-treasury-db.sh, and neither the
# backup nor the verification prints the name of the off-host remote on mainnet: it says where the
# backups live, and the logs are public. The workflow gets its source from the environment as well.
if grep -qF 'chain_compose run --rm --no-deps' scripts/verify-restored-ledger.sh; then
  pass "verify-restored-ledger.sh reconciles through the chain's own compose definition"
else
  fail "verify-restored-ledger.sh reconciles through the chain's own compose definition"
fi
if [ "$(grep -cF 'CHAIN="$CH_NAME" RESTORE_TARGET=' scripts/verify-restored-ledger.sh)" -eq 2 ]; then
  pass "verify-restored-ledger.sh passes the chain on to both restores"
else
  fail "verify-restored-ledger.sh passes the chain on to both restores"
fi
if grep -qF "its name is not printed: the log is public" scripts/verify-restored-ledger.sh \
   && grep -qF "its name is not printed: the log is public" scripts/backup-treasury-db.sh; then
  pass "the mainnet remote's name is printed by neither the backup nor the verification"
else
  fail "the mainnet remote's name is printed by neither the backup nor the verification"
fi
if grep -qF 'ENV_FILE="$CH_ENV_FILE"' scripts/restore-treasury-db.sh && grep -qF 'grep -E "^$1=" "$ENV_FILE"' scripts/restore-treasury-db.sh; then
  pass "restore-treasury-db.sh reads the chain's env file"
else
  fail "restore-treasury-db.sh reads the chain's env file"
fi
if grep -qF 'SOURCE: ${{ inputs.source }}' .github/workflows/rehearse-restore.yml && ! grep -qF '"${{ inputs.source }}"' .github/workflows/rehearse-restore.yml; then
  pass "rehearse-restore.yml passes its source through the environment"
else
  fail "rehearse-restore.yml passes its source through the environment"
fi

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
