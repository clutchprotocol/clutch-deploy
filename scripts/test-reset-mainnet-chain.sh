#!/usr/bin/env bash
# Self-check for reset-mainnet-chain.sh, the script that deletes the mainnet chain. CI runs it
# (test-treasury-scripts.yml) with a fake `docker`, a copy of the real node configs and fixture env
# files in a temp directory: no host, no network, nothing is deleted. What it proves is the part that
# must never fail: every gate that should stop the wipe stops it BEFORE anything is halted, stopped or
# removed, and the order of a real reset is halt, stop, copy, delete.
set -euo pipefail
cd "$(dirname "$0")/.."

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts/lib" "$T/bin" "$T/config/node-mainnet"
cp scripts/reset-mainnet-chain.sh scripts/check-genesis.sh "$T/scripts/"
cp scripts/lib/chain.sh "$T/scripts/lib/"
cp config/node-mainnet/node1.toml config/node-mainnet/node2.toml config/node-mainnet/node3.toml "$T/config/node-mainnet/"

ADDRESS=0x00000000000000000000000000000000000000c3
SECRET=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

# The real node configs, with the new mint address in place of the real one, as they will be after the
# change that sets it.
set_address() {  # set_address <address> <node numbers...>
  local a="$1" n
  shift
  for n in "$@"; do
    sed -i "s/^mint_authority = \"0x[0-9a-fA-F]*\"/mint_authority = \"$a\"/" "$T/config/node-mainnet/node${n}.toml"
  done
}
set_address "$ADDRESS" 1 2 3
cp "$T/config/node-mainnet/node2.toml" "$T/node2.good"

# halt-minting.sh has its own test. Here it only records that it was called, and with what.
cat > "$T/scripts/halt-minting.sh" <<'EOF'
#!/usr/bin/env bash
echo "HALT chain=$CHAIN reason=$REASON" >> "$FAKE_CALLS"
echo "(halt called)"
EOF

# The fake docker. It answers what the script asks, from FAKE_* values, and writes every call to
# $FAKE_CALLS. The archive it "creates" is a real gzip file, because the script tests it.
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$FAKE_CALLS"
case "$1" in
  inspect)
    # An unset FAKE_KIND is a container that does not exist.
    [ -n "${FAKE_KIND+x}" ] || exit 1
    printf 'PATH=/usr/bin\nAPP_SIGNER_KIND=%s\nAPP_OTHER=x\n' "$FAKE_KIND"
    ;;
  exec)
    sql="${*: -1}"
    case "$sql" in
      *treasury_events*)      echo "${FAKE_MINTED:-0}" ;;
      *mint_intents*)         echo "${FAKE_LIVE:-0}" ;;
      *reconciliation_runs*)  echo "${FAKE_SUPPLY:-0}" ;;
    esac
    ;;
  volume)
    [ "$2" = inspect ] && exit "${FAKE_VOLUME_RC:-0}"
    ;;
  run)
    case "$*" in
      *"--entrypoint du"*) printf '1234\t/d\n' ;;
      *"--entrypoint tar"*)
        host=""; file=""
        args=("$@")
        for i in "${!args[@]}"; do
          case "${args[$i]}" in
            -v) case "${args[$((i + 1))]}" in *:/b) host="${args[$((i + 1))]%:/b}" ;; esac ;;
            czf) file="${args[$((i + 1))]#/b/}" ;;
          esac
        done
        echo "an archive" | gzip > "$host/$file"
        ;;
      *curlimages*) echo "latest_block_index 42" ;;
    esac
    ;;
esac
exit 0
EOF
chmod +x "$T/bin/docker"

passed=0
failed=0
out=""
code=0

check() {  # check <name> <condition...>: the condition is a command; its exit status is the verdict
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

fresh() {  # fresh: a clean host: the key in .env.mainnet, good configs, no calls, no backups
  rm -rf "$T/backups" "$T/calls"
  : > "$T/calls"
  printf '%s\n' "OTHER=1" "MINT_AUTHORITY_SECRET=$SECRET" "MINT_AUTHORITY_ADDRESS=$ADDRESS" > "$T/.env.mainnet"
  cp "$T/node2.good" "$T/config/node-mainnet/node2.toml"
  unset FAKE_KIND FAKE_MINTED FAKE_LIVE FAKE_SUPPLY FAKE_VOLUME_RC
  export FAKE_KIND=azure_kms
}

run() {  # run <mode>
  code=0
  out=$(env -i PATH="$T/bin:$PATH" TMPDIR="$T" MODE="$1" FAKE_CALLS="$T/calls" \
          ${FAKE_KIND+FAKE_KIND="$FAKE_KIND"} ${FAKE_MINTED+FAKE_MINTED="$FAKE_MINTED"} \
          ${FAKE_LIVE+FAKE_LIVE="$FAKE_LIVE"} ${FAKE_SUPPLY+FAKE_SUPPLY="$FAKE_SUPPLY"} \
          ${FAKE_VOLUME_RC+FAKE_VOLUME_RC="$FAKE_VOLUME_RC"} \
          bash "$T/scripts/reset-mainnet-chain.sh" 2>&1) || code=$?
}

said() { printf '%s' "$out" | grep -qF -- "$1"; }
called() { grep -qF -- "$1" "$T/calls"; }
# Nothing was halted, stopped, copied or removed.
untouched() {
  ! called "HALT" && ! called " stop" && ! called "--entrypoint tar" && ! called " down" \
    && [ -z "$(find "$T/backups" -mindepth 1 -maxdepth 1 -name 'mainnet-chain-*' 2>/dev/null)" ]
}
line_of() { grep -nF -- "$1" "$T/calls" | head -1 | cut -d: -f1; }

# 1. check mode, with everything in order: the gates pass and nothing is changed.
fresh
run check
check "check mode passes every gate" eval '[ "$code" -eq 0 ] && said "Every gate passed. Nothing was changed."'
check "check mode changes nothing" untouched
check "check mode says what it counted" eval 'said "mint events in the ledger:" && said "supply on chain at the last reconciliation"'

# 2. reset mode, with everything in order: halt, then stop, then copy, then delete.
fresh
run reset
check "reset mode succeeds" eval '[ "$code" -eq 0 ] && said "The old chain is gone"'
check "reset mode halts first, then stops, then copies, then deletes" eval \
  '[ "$(line_of HALT)" -lt "$(line_of " stop")" ] && [ "$(line_of " stop")" -lt "$(line_of "--entrypoint tar")" ] && [ "$(line_of "--entrypoint tar")" -lt "$(line_of " down -v")" ]'
check "the halt is for the mainnet treasury" called "HALT chain=mainnet"
check "all three volumes are copied, and the copy is kept with a note" eval \
  'b=$(find "$T/backups" -mindepth 1 -maxdepth 1 -name "mainnet-chain-*"); [ -s "$b/node1.tgz" ] && [ -s "$b/node2.tgz" ] && [ -s "$b/node3.tgz" ] && [ -s "$b/README" ]'
check "the project that is deleted is the mainnet chain" called "docker compose -p clutch-main -f docker-compose.mainnet.yml down -v"
check "the note in the copy names the mint address and how the treasury signed" eval \
  'b=$(find "$T/backups" -mindepth 1 -maxdepth 1 -name "mainnet-chain-*"); grep -qF "$ADDRESS" "$b/README" && grep -qF "signed with: azure_kms" "$b/README"'
check "the halt gives a reason that is true for every reset" called "HALT chain=mainnet reason=mainnet chain reset"

# 2b. The same reset, on the host as it is since 2026-10-05: the treasury signs with the key on the host.
# This used to refuse (the gate wanted azure_kms), which would have made a second reset impossible.
fresh; export FAKE_KIND=env
run check
check "a treasury that signs with the host key passes every gate (check)" eval '[ "$code" -eq 0 ] && said "Every gate passed" && said "APP_SIGNER_KIND of" && untouched'
fresh; export FAKE_KIND=env
run reset
check "a treasury that signs with the host key can be reset again" eval '[ "$code" -eq 0 ] && said "The old chain is gone"'
check "the order is the same: halt, stop, copy, delete" eval \
  '[ "$(line_of HALT)" -lt "$(line_of " stop")" ] && [ "$(line_of " stop")" -lt "$(line_of "--entrypoint tar")" ] && [ "$(line_of "--entrypoint tar")" -lt "$(line_of " down -v")" ]'
check "the note in the copy says the treasury signed with the host key" eval \
  'b=$(find "$T/backups" -mindepth 1 -maxdepth 1 -name "mainnet-chain-*"); grep -qF "signed with: env" "$b/README"'

# 3. Each gate that must stop it, and stop it before anything changes.
fresh; export FAKE_KIND=hsm
run reset
check "a treasury that signs in a way the script does not know stops it" eval '[ "$code" -eq 1 ] && said "signs in a way this script does not know" && untouched'
fresh; unset FAKE_KIND
run reset
check "a treasury container that is not there stops it" eval '[ "$code" -eq 1 ] && said "<no such container>" && said "container is missing" && untouched'
fresh; export FAKE_KIND=env; export FAKE_MINTED=3
run reset
check "a mint in the ledger stops it, on the host-key treasury too" eval '[ "$code" -eq 1 ] && said "CLT exists" && untouched'
fresh; export FAKE_MINTED=3
run reset
check "a mint in the ledger stops it" eval '[ "$code" -eq 1 ] && said "CLT exists" && untouched'
fresh; export FAKE_LIVE=1
run reset
check "a mint intent in flight stops it" eval '[ "$code" -eq 1 ] && said "CLT exists" && untouched'
fresh; export FAKE_SUPPLY=5000000
run reset
check "supply on chain stops it" eval '[ "$code" -eq 1 ] && said "CLT exists" && untouched'
fresh; export FAKE_MINTED=abc
run reset
check "an answer that is not a number stops it" eval '[ "$code" -eq 1 ] && said "is not a number" && untouched'
fresh; export FAKE_VOLUME_RC=1
run reset
check "a missing volume stops it" eval '[ "$code" -eq 1 ] && said "no volume clutch-main_mainnet-node1-data" && untouched'
fresh; set_address 0x00000000000000000000000000000000000000d4 2
run reset
check "a node config with another mint_authority stops it" eval '[ "$code" -eq 1 ] && said "node2.toml has a mint_authority that is not MINT_AUTHORITY_ADDRESS" && untouched'
fresh; sed -i '/^MINT_AUTHORITY_SECRET=/d' "$T/.env.mainnet"
run reset
check "no mint key stops it" eval '[ "$code" -eq 1 ] && said "is not a 64-character hex key" && untouched'
fresh; sed -i '/^MINT_AUTHORITY_ADDRESS=/d' "$T/.env.mainnet"
run reset
check "no recorded address stops it" eval '[ "$code" -eq 1 ] && said "MINT_AUTHORITY_ADDRESS in .env.mainnet is missing" && untouched'
fresh
run oops
check "a mode that is neither check nor reset stops it" eval '[ "$code" -eq 1 ] && said "MODE must be check or reset" && untouched'

# 4. The key is never printed.
fresh
run reset
check "the secret is never printed" eval '! said "$SECRET"'

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
